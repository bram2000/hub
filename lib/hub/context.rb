require 'shellwords'
require 'forwardable'
require 'uri'

module Hub
  # Provides methods for inspecting the environment, such as GitHub user/token
  # settings, repository info, and similar.
  module Context
    extend Forwardable

    NULL = defined?(File::NULL) ? File::NULL : File.exist?('/dev/null') ? '/dev/null' : 'NUL'

    # Shells out to git to get output of its commands
    class GitReader
      attr_reader :executable

      def initialize(executable = nil, &read_proc)
        @executable = executable || 'git'
        # caches output when shelling out to git
        read_proc ||= lambda { |cache, cmd|
          result = %x{#{command_to_string(cmd)} 2>#{NULL}}.chomp
          cache[cmd] = $?.success? && !result.empty? ? result : nil
        }
        @cache = Hash.new(&read_proc)
      end

      def add_exec_flags(flags)
        @executable = Array(executable).concat(flags)
      end

      def read_config(cmd, all = false)
        config_cmd = ['config', (all ? '--get-all' : '--get'), *cmd]
        config_cmd = config_cmd.join(' ') unless cmd.respond_to? :join
        read config_cmd
      end

      def read(cmd)
        @cache[cmd]
      end

      def stub_config_value(key, value, get = '--get')
        stub_command_output "config #{get} #{key}", value
      end

      def stub_command_output(cmd, value)
        @cache[cmd] = value.nil? ? nil : value.to_s
      end

      def stub!(values)
        @cache.update values
      end

      private

      def to_exec(args)
        args = Shellwords.shellwords(args) if args.respond_to? :to_str
        Array(executable) + Array(args)
      end

      def command_to_string(cmd)
        full_cmd = to_exec(cmd)
        full_cmd.respond_to?(:shelljoin) ? full_cmd.shelljoin : full_cmd.join(' ')
      end
    end

    module GitReaderMethods
      extend Forwardable

      def_delegator :git_reader, :read_config, :git_config
      def_delegator :git_reader, :read, :git_command

      def self.extended(base)
        base.extend Forwardable
        base.def_delegators :'self.class', :git_config, :git_command
      end
    end

    private

    def git_reader
      @git_reader ||= GitReader.new ENV['GIT']
    end

    include GitReaderMethods
    private :git_config, :git_command

    def local_repo(fatal = true)
      @local_repo ||= begin
        if is_repo?
          LocalRepo.new git_reader, current_dir
        elsif fatal
          abort "fatal: Not a git repository"
        end
      end
    end

    repo_methods = [
      :current_branch, :master_branch,
      :current_project, :upstream_project,
      :repo_owner, :repo_host,
      :remotes, :remotes_group, :origin_remote
    ]
    def_delegator :local_repo, :name, :repo_name
    def_delegators :local_repo, *repo_methods
    private :repo_name, *repo_methods

    class LocalRepo < Struct.new(:git_reader, :dir)
      include GitReaderMethods

      def name
        if project = main_project
          project.name
        else
          File.basename(dir)
        end
      end

      def repo_owner
        if project = main_project
          project.owner
        end
      end

      def repo_host
        project = main_project and project.host
      end

      def main_project
        remote = origin_remote and remote.project
      end

      def upstream_project
        if branch = current_branch and upstream = branch.upstream and upstream.remote?
          remote = remote_by_name upstream.remote_name
          remote.project
        end
      end

      def current_project
        upstream_project || main_project
      end

      def current_branch
        if branch = git_command('symbolic-ref -q HEAD')
          Branch.new self, branch
        end
      end

      def master_branch
        Branch.new self, 'refs/heads/master'
      end

      def remotes
        @remotes ||= begin
          # TODO: is there a plumbing command to get a list of remotes?
          list = git_command('remote').to_s.split("\n")
          # force "origin" to be first in the list
          main = list.delete('origin') and list.unshift(main)
          list.map { |name| Remote.new self, name }
        end
      end

      def remotes_group(name)
        git_config "remotes.#{name}"
      end

      def origin_remote
        remotes.first
      end

      def remote_by_name(remote_name)
        remotes.find {|r| r.name == remote_name }
      end

      def known_hosts
        git_config('hub.host', :all).to_s.split("\n") + [default_host]
      end

      def default_host
        ENV['GITHUB_HOST'] || main_host
      end

      def main_host
        'github.com'
      end

      def ssh_config
        @ssh_config ||= SshConfig.new
      end
    end

    class GithubProject < Struct.new(:local_repo, :owner, :name, :host)
      def self.from_url(url, local_repo)
        if local_repo.known_hosts.include? url.host
          _, owner, name = url.path.split('/', 4)
          GithubProject.new(local_repo, owner, name.sub(/\.git$/, ''), url.host)
        end
      end

      def initialize(*args)
        super
        self.host ||= local_repo.default_host
      end

      def private?
        local_repo and host != local_repo.main_host
      end

      def owned_by(new_owner)
        new_project = dup
        new_project.owner = new_owner
        new_project
      end

      def name_with_owner
        "#{owner}/#{name}"
      end

      def ==(other)
        name_with_owner == other.name_with_owner
      end

      def remote
        local_repo.remotes.find { |r| r.project == self }
      end

      def web_url(path = nil)
        project_name = name_with_owner
        if project_name.sub!(/\.wiki$/, '')
          unless '/wiki' == path
            path = if path =~ %r{^/commits/} then '/_history'
                   else path.to_s.sub(/\w+/, '_\0')
                   end
            path = '/wiki' + path
          end
        end
        "https://#{host}/" + project_name + path.to_s
      end

      def git_url(options = {})
        if options[:https] then "https://#{host}/"
        elsif options[:private] or private? then "git@#{host}:"
        else "git://#{host}/"
        end + name_with_owner + '.git'
      end

      def api_url(type, resource, action)
        URI("https://#{host}/api/v2/#{type}/#{resource}/#{action}")
      end

      def api_show_url(type)
        api_url(type, 'repos', "show/#{owner}/#{name}")
      end

      def api_fork_url(type)
        api_url(type, 'repos', "fork/#{owner}/#{name}")
      end

      def api_create_url(type)
        api_url(type, 'repos', 'create')
      end

      def api_pullrequest_url(id, type)
        api_url(type, 'pulls', "#{owner}/#{name}/#{id}")
      end

      def api_create_pullrequest_url(type)
        api_url(type, 'pulls', "#{owner}/#{name}")
      end
    end

    class GithubURL < URI::HTTPS
      extend Forwardable

      attr_reader :project
      def_delegator :project, :name, :project_name
      def_delegator :project, :owner, :project_owner

      def self.resolve(url, local_repo)
        u = URI(url)
        if %[http https].include? u.scheme and project = GithubProject.from_url(u, local_repo)
          self.new(u.scheme, u.userinfo, u.host, u.port, u.registry,
                   u.path, u.opaque, u.query, u.fragment, project)
        end
      rescue URI::InvalidURIError
        nil
      end

      def initialize(*args)
        @project = args.pop
        super(*args)
      end

      # segment of path after the project owner and name
      def project_path
        path.split('/', 4)[3]
      end
    end

    class Branch < Struct.new(:local_repo, :name)
      alias to_s name

      def short_name
        name.sub(%r{^refs/(remotes/)?.+?/}, '')
      end

      def master?
        short_name == 'master'
      end

      def upstream
        if branch = local_repo.git_command("rev-parse --symbolic-full-name #{short_name}@{upstream}")
          Branch.new local_repo, branch
        end
      end

      def remote?
        name.index('refs/remotes/') == 0
      end

      def remote_name
        name =~ %r{^refs/remotes/([^/]+)} and $1 or
          raise "can't get remote name from #{name.inspect}"
      end
    end

    class Remote < Struct.new(:local_repo, :name)
      alias to_s name

      def ==(other)
        other.respond_to?(:to_str) ? name == other.to_str : super
      end

      def project
        urls.each { |url|
          if valid = GithubProject.from_url(url, local_repo)
            return valid
          end
        }
        nil
      end

      def urls
        @urls ||= local_repo.git_config("remote.#{name}.url", :all).to_s.split("\n").map { |uri|
          begin
            if uri =~ %r{^[\w-]+://}    then uri_parse(uri)
            elsif uri =~ %r{^([^/]+?):} then uri_parse("ssh://#{$1}/#{$'}")  # scp-like syntax
            end
          rescue URI::InvalidURIError
            nil
          end
        }.compact
      end

      def uri_parse uri
        uri = URI.parse uri
        uri.host = local_repo.ssh_config.get_value(uri.host, 'hostname') { uri.host }
        uri.user = local_repo.ssh_config.get_value(uri.host, 'user') { uri.user }
        uri
      end
    end

    ## helper methods for local repo, GH projects

    def github_project(name, owner = nil)
      if owner and owner.index('/')
        owner, name = owner.split('/', 2)
      elsif name and name.index('/')
        owner, name = name.split('/', 2)
      else
        name ||= repo_name
        owner ||= github_user
      end

      if local_repo(false) and main_project = local_repo.main_project
        project = main_project.dup
        project.owner = owner
        project.name = name
        project
      else
        GithubProject.new(local_repo, owner, name)
      end
    end

    def git_url(owner = nil, name = nil, options = {})
      project = github_project(name, owner)
      project.git_url({:https => https_protocol?}.update(options))
    end

    def resolve_github_url(url)
      GithubURL.resolve(url, local_repo) if url =~ /^https?:/
    end

    LGHCONF = "http://help.github.com/set-your-user-name-email-and-github-token/"

    # Either returns the GitHub user as set by git-config(1) or aborts
    # with an error message.
    def github_user(fatal = true, host = nil)
      if local = local_repo(false)
        host ||= local.default_host
        host = nil if host == local.main_host
      end
      host = %(."#{host}") if host
      if user = ENV['GITHUB_USER'] || git_config("github#{host}.user")
        user
      elsif fatal
        if host.nil?
          abort("** No GitHub user set. See #{LGHCONF}")
        else
          abort("** No user set for github#{host}")
        end
      end
    end

    def github_token(fatal = true, host = nil)
      if local = local_repo(false)
        host ||= local.default_host
        host = nil if host == local.main_host
      end
      host = %(."#{host}") if host
      if token = ENV['GITHUB_TOKEN'] || git_config("github#{host}.token")
        token
      elsif fatal
        if host.nil?
          abort("** No GitHub token set. See #{LGHCONF}")
        else
          abort("** No token set for github#{host}")
        end
      end
    end

    # legacy setting
    def http_clone?
      git_config('--bool hub.http-clone') == 'true'
    end

    def https_protocol?
      git_config('hub.protocol') == 'https' or http_clone?
    end

    def git_alias_for(name)
      git_config "alias.#{name}"
    end

    def rev_list(a, b)
      git_command("rev-list --cherry-pick --right-only --no-merges #{a}...#{b}")
    end

    PWD = Dir.pwd

    def current_dir
      PWD
    end

    def git_dir
      git_command 'rev-parse -q --git-dir'
    end

    def is_repo?
      !!git_dir
    end

    def git_editor
      # possible: ~/bin/vi, $SOME_ENVIRONMENT_VARIABLE, "C:\Program Files\Vim\gvim.exe" --nofork
      editor = git_command 'var GIT_EDITOR'
      editor = ENV[$1] if editor =~ /^\$(\w+)$/
      editor = File.expand_path editor if (editor =~ /^[~.]/ or editor.index('/')) and editor !~ /["']/
      editor.shellsplit
    end

    # Cross-platform web browser command; respects the value set in $BROWSER.
    # 
    # Returns an array, e.g.: ['open']
    def browser_launcher
      browser = ENV['BROWSER'] || (
        osx? ? 'open' : windows? ? 'start' :
        %w[xdg-open cygstart x-www-browser firefox opera mozilla netscape].find { |comm| which comm }
      )

      abort "Please set $BROWSER to a web launcher to use this command." unless browser
      Array(browser)
    end

    def osx?
      require 'rbconfig'
      RbConfig::CONFIG['host_os'].to_s.include?('darwin')
    end

    def windows?
      require 'rbconfig'
      RbConfig::CONFIG['host_os'] =~ /msdos|mswin|djgpp|mingw|windows/
    end

    # Cross-platform way of finding an executable in the $PATH.
    #
    #   which('ruby') #=> /usr/bin/ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each { |ext|
          exe = "#{path}/#{cmd}#{ext}"
          return exe if File.executable? exe
        }
      end
      return nil
    end

    # Checks whether a command exists on this system in the $PATH.
    #
    # name - The String name of the command to check for.
    #
    # Returns a Boolean.
    def command?(name)
      !which(name).nil?
    end

    class SshConfig
      CONFIG_FILES = %w(~/.ssh/config /etc/ssh_config /etc/ssh/ssh_config)

      def initialize files = nil
        @settings = Hash.new {|h,k| h[k] = {} }
        Array(files || CONFIG_FILES).each do |path|
          file = File.expand_path path
          parse_file file if File.exist? file
        end
      end

      # yields if not found
      def get_value hostname, key
        key = key.to_s.downcase
        @settings.each do |pattern, settings|
          if pattern.match? hostname and found = settings[key]
            return found
          end
        end
        yield
      end

      class HostPattern
        def initialize pattern
          @pattern = pattern.to_s.downcase
        end

        def to_s() @pattern end
        def ==(other) other.to_s == self.to_s end

        def matcher
          @matcher ||=
            if '*' == @pattern
              Proc.new { true }
            elsif @pattern !~ /[?*]/
              lambda { |hostname| hostname.to_s.downcase == @pattern }
            else
              re = self.class.pattern_to_regexp @pattern
              lambda { |hostname| re =~ hostname }
            end
        end

        def match? hostname
          matcher.call hostname
        end

        def self.pattern_to_regexp pattern
          escaped = Regexp.escape(pattern)
          escaped.gsub!('\*', '.*')
          escaped.gsub!('\?', '.')
          /^#{escaped}$/i
        end
      end

      def parse_file file
        host_patterns = [HostPattern.new('*')]

        IO.foreach(file) do |line|
          case line
          when /^\s*(#|$)/ then next
          when /^\s*(\S+)\s*=/
            key, value = $1, $'
          else
            key, value = line.strip.split(/\s+/, 2)
          end

          next if value.nil?
          key.downcase!
          value = $1 if value =~ /^"(.*)"$/
          value.chomp!

          if 'host' == key
            host_patterns = value.split(/\s+/).map {|p| HostPattern.new p }
          else
            record_setting key, value, host_patterns
          end
        end
      end

      def record_setting key, value, patterns
        patterns.each do |pattern|
          @settings[pattern][key] ||= value
        end
      end
    end
  end
end