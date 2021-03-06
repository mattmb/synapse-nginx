require 'synapse/config_generator/base'

require 'fileutils'
require 'logger'

class Synapse::ConfigGenerator
  class Nginx < BaseGenerator
    include Synapse::Logging

    NAME = 'nginx'.freeze

    def initialize(opts)
      %w{main events}.each do |req|
        if !opts.fetch('contexts', {}).has_key?(req)
          raise ArgumentError, "nginx requires a contexts.#{req} section"
        end
      end

      @opts = opts
      @contexts = opts['contexts']
      @opts['do_writes'] = true unless @opts.key?('do_writes')
      @opts['do_reloads'] = true unless @opts.key?('do_reloads')

      req_pairs = {
        'do_writes' => ['config_file_path', 'check_command'],
        'do_reloads' => ['reload_command', 'start_command'],
      }

      req_pairs.each do |cond, reqs|
        if opts[cond]
          unless reqs.all? {|req| opts[req]}
            missing = reqs.select {|req| not opts[req]}
            raise ArgumentError, "the `#{missing}` option(s) are required when `#{cond}` is true"
          end
        end
      end

      # how to restart nginx
      @restart_interval = @opts.fetch('restart_interval', 2).to_i
      @restart_jitter = @opts.fetch('restart_jitter', 0).to_f
      @restart_required = false
      @has_started = false

      # virtual clock bookkeeping for controlling how often nginx restarts
      @time = 0
      @next_restart = @time

      # a place to store generated server + upstream stanzas, and watcher
      # revisions so we can save CPU on updates by not re-computing stanzas
      @servers_cache = {}
      @upstreams_cache = {}
      @watcher_revisions = {}
    end

    def normalize_watcher_provided_config(service_watcher_name, service_watcher_config)
      service_watcher_config = super(service_watcher_name, service_watcher_config)
      defaults = {
        'mode' => 'http',
        'upstream' => [],
        'server' => [],
        'disabled' => false,
      }

      unless service_watcher_config.include?('port') || service_watcher_config['disabled']
        log.warn "synapse: service #{service_watcher_name}: nginx config does not include a port; only upstream sections for the service will be created; you must move traffic there manually using server sections"
      end

      defaults.merge(service_watcher_config)
    end

    def tick(watchers)
      @time += 1

      # Always ensure we try to start at least once
      # Note that this should only trigger during error cases where for
      # some reason Synapse could not start NGINX during the initial restart
      start if opts['do_reloads'] && !@has_started

      # We potentially have to restart if the restart was rate limited
      # in the original call to update_config
      restart if opts['do_reloads'] && @restart_required
    end

    def update_config(watchers)
      # generate a new config
      new_config = generate_config(watchers)

      # if we write config files, lets do that and then possibly restart
      if opts['do_writes']
        @restart_required = write_config(new_config)
        restart if opts['do_reloads'] && @restart_required
      end
    end

    # generates a new config based on the state of the watchers
    def generate_config(watchers)
      new_config = generate_base_config

      http = (@contexts['http'] || []).collect {|option| "\t#{option};"}
      stream = (@contexts['stream'] || []).collect {|option| "\t#{option};"}

      watchers.each do |watcher|
        watcher_config = watcher.config_for_generator[name]
        next if watcher_config['disabled']
        # There seems to be no way to have empty TCP listeners ... just
        # don't bind the port at all? ... idk
        next if watcher_config['mode'] == 'tcp' && watcher.backends.empty?


        # Only regenerate if something actually changed. This saves a lot
        # of CPU load for high churn systems
        regenerate = watcher.revision != @watcher_revisions[watcher.name] ||
                     @servers_cache[watcher.name].nil? ||
                     @upstreams_cache[watcher.name].nil?

        if regenerate
          @servers_cache[watcher.name] = generate_server(watcher).flatten
          @upstreams_cache[watcher.name] = generate_upstream(watcher).flatten
          @watcher_revisions[watcher.name] = watcher.revision
        end

        section = case watcher_config['mode']
          when 'http'
            http
          when 'tcp'
            stream
          else
            raise ArgumentError, "synapse does not understand #{watcher_config['mode']} as a service mode"
        end
        section << @servers_cache[watcher.name]
        section << @upstreams_cache[watcher.name]
      end

      unless http.empty?
        new_config << 'http {'
        new_config.concat(http.flatten)
        new_config << "}\n"
      end

      unless stream.empty?
        new_config << 'stream {'
        new_config.concat(stream.flatten)
        new_config << "}\n"
      end

      log.debug "synapse: new nginx config: #{new_config}"
      return new_config.flatten.join("\n")
    end

    # generates the global and defaults sections of the config file
    def generate_base_config
      base_config = ["# auto-generated by synapse at #{Time.now}\n"]

      # The "main" context is special and is the top level
      @contexts['main'].each do |option|
        base_config << "#{option};"
      end
      base_config << "\n"

      # http and streams are generated separately
      @contexts.keys.select{|key| !(["main", "http", "stream"].include?(key))}.each do |context|
        base_config << "#{context} {"
        @contexts[context].each do |option|
          base_config << "\t#{option};"
        end
        base_config << "}\n"
      end
      return base_config
    end

    def generate_server(watcher)
      watcher_config = watcher.config_for_generator[name]
      unless watcher_config.has_key?('port')
        log.debug "synapse: not generating server stanza for watcher #{watcher.name} because it has no port defined"
        return []
      else
        port = watcher_config['port']
      end

      listen_address = (
        watcher_config['listen_address'] ||
        opts['listen_address'] ||
        'localhost'
      )

      listen_line= [
        "\t\tlisten",
        "#{listen_address}:#{port}",
        watcher_config['listen_options'],
        ';',
      ].compact.join(' ')


      upstream_name = watcher_config.fetch('upstream_name', watcher.name)
      stanza = [
        "\tserver {",
        listen_line,
        watcher_config['server'].map {|c| "\t\t#{c};"},
        generate_proxy(watcher_config['mode'], upstream_name, watcher.backends.empty?),
        "\t}",
      ]
    end

    # Nginx has some annoying differences between how upstreams in the
    # http (http) module and the stream (tcp) module address upstreams
    def generate_proxy(mode, upstream_name, empty_upstream)
      upstream_name = "http://#{upstream_name}" if mode == 'http'

      case mode
      when 'http'
        if empty_upstream
          value = "\t\t\treturn 503;"
        else
          value = "\t\t\tproxy_pass #{upstream_name};"
        end
        stanza = [
          "\t\tlocation / {",
          value,
          "\t\t}"
        ]
      when 'tcp'
        stanza = [
          "\t\tproxy_pass #{upstream_name};",
        ]
      else
        []
      end
    end

    def generate_upstream(watcher)
      backends = {}
      watcher_config = watcher.config_for_generator[name]
      upstream_name = watcher_config.fetch('upstream_name', watcher.name)

      watcher.backends.each {|b| backends[construct_name(b)] = b}

      # nginx doesn't like upstreams with no backends?
      return [] if backends.empty?

      # Note that because we use the config file as the source of truth
      # for whether or not to reload, we want some kind of sorted order
      # by default, in this case we choose asc
      keys = case watcher_config['upstream_order']
      when 'desc'
        backends.keys.sort.reverse
      when 'shuffle'
        backends.keys.shuffle
      when 'no_shuffle'
        backends.keys
      else
        backends.keys.sort
      end

      stanza = [
        "\tupstream #{upstream_name} {",
        watcher_config['upstream'].map {|c| "\t\t#{c};"},
        keys.map {|backend_name|
          backend = backends[backend_name]
          b = "\t\tserver #{backend['host']}:#{backend['port']}"
          b = "#{b} #{watcher_config['server_options']}" if watcher_config['server_options']
          "#{b};"
        },
        "\t}"
      ]
    end

    # writes the config
    def write_config(new_config)
      begin
        old_config = File.read(opts['config_file_path'])
      rescue Errno::ENOENT => e
        log.info "synapse: could not open nginx config file at #{opts['config_file_path']}"
        old_config = ""
      end

      # The first line of the config files contain a timestamp, so to prevent
      # un-needed restarts, only compare after that. We do not split on
      # newlines and compare because this is called a lot, and we need to be
      # as CPU efficient as possible.
      old_version =  old_config[(old_config.index("\n") || 0) + 1..-1]
      new_version =  new_config[(new_config.index("\n") || 0) + 1..-1]
      if old_version == new_version
        return false
      else
        File.open(opts['config_file_path'],'w') {|f| f.write(new_config)}
        check = `#{opts['check_command']}`.chomp
        unless $?.success?
          log.error "synapse: nginx configuration is invalid according to #{opts['check_command']}!"
          log.error 'synapse: not restarting nginx as a result'
          return false
        end

        return true
      end
    end

    def start
      log.info "synapse: attempting to run #{opts['start_command']} to get nginx started"
      log.info 'synapse: this can fail if nginx is already running'
      begin
        `#{opts['start_command']}`.chomp
      rescue Exception => e
        log.warn "synapse: error in NGINX start: #{e.inspect}"
        log.warn e.backtrace
      ensure
        @has_started = true
      end
    end

    # restarts nginx if the time is right
    def restart
      if @time < @next_restart
        log.info "synapse: at time #{@time} waiting until #{@next_restart} to restart"
        return
      end

      @next_restart = @time + @restart_interval
      @next_restart += rand(@restart_jitter * @restart_interval + 1)

      # On the very first restart we may need to start
      start unless @has_started

      res = `#{opts['reload_command']}`.chomp
      unless $?.success?
        log.error "failed to reload nginx via #{opts['reload_command']}: #{res}"
        return
      end
      log.info "synapse: restarted nginx"

      @restart_required = false
    end

    # used to build unique, consistent nginx names for backends
    def construct_name(backend)
      name = "#{backend['host']}:#{backend['port']}"
      if backend['name'] && !backend['name'].empty?
        name = "#{backend['name']}_#{name}"
      end

      return name
    end
  end
end
