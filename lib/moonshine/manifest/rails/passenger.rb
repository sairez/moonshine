module Moonshine::Manifest::Rails::Passenger

  BLESSED_VERSION = '4.0.45'

  # Install the passenger gem
  def passenger_gem
    configure(:passenger => {})
    package 'libcurl4-openssl-dev', :ensure => :installed

    if configuration[:passenger][:enterprise]
      exec 'remove passenger',
        :command => 'gem uninstall passenger --all',
        :onlyif => "gem list | grep 'passenger '"

      if configuration[:passenger][:download_token] or configuration[:passenger][:order_reference]
        if configuration[:passenger][:download_token]
          download_token = configuration[:passenger][:download_token]
          source_url = "https://download:#{download_token}@www.phusionpassenger.com/enterprise_gems/"
        elsif configuration[:passenger][:order_reference]
          puts "WARNING: Phusion has removed using ORDER REFERENCE/ORDER PASSWORD for authentication to their gem server."
          puts "Please set the :passenger: => :download_token: setting in your moonshine.yml before December 1, 2013."
          exit 1
        end

        exec 'configure passenger enterprise gem source',
          :command => "gem source --add #{source_url}",
          :unless => "gem source | grep '#{source_url}'"

        if configuration[:passenger][:version].nil? || configuration[:passenger][:version] == :latest
          package 'passenger',
            :name => 'passenger-enterprise-server',
            :ensure => BLESSED_VERSION,
            :provider => :gem,
            :require => [ package('libcurl4-openssl-dev'), exec('remove passenger'), exec('configure passenger enterprise gem source') ]
        elsif configuration[:passenger][:version]
          package 'passenger',
            :name => 'passenger-enterprise-server',
            :ensure => configuration[:passenger][:version],
            :provider => :gem,
            :require => [ package('libcurl4-openssl-dev'), exec('remove passenger'), exec('configure passenger enterprise gem source') ]
        end
      else
        raise "Passenger Enterprise enabled, but no gemfile specified. Update config/moonshine.yml with :gemfile for :passenger and try again" unless configuration[:passenger][:gemfile]

        package "remove passenger",
          :name => "passenger",
          :provider => :gem,
          :ensure => :absent

        exec 'install passenger-enterprise-server gem',
          :command => "gem install #{configuration[:passenger][:gemfile]}",
          :unless => "gem list | grep passenger-enterprise-server | grep #{configuration[:passenger][:version]}",
          :cwd => rails_root,
          :require => [ package('libcurl4-openssl-dev'), exec('remove passenger')]
      end

      file '/etc/passenger-enterprise-license',
        :ensure => :present,
        :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger-enterprise-license'))
    elsif configuration[:passenger][:version] && configuration[:passenger][:version] < "3.0"
      package "passenger",
        :ensure => configuration[:passenger][:version],
        :provider => :gem
    elsif configuration[:passenger][:version].nil? || configuration[:passenger][:version] == :latest
      package "passenger",
        :ensure => BLESSED_VERSION,
        :provider => :gem,
        :require => [ package('libcurl4-openssl-dev') ]
    elsif configuration[:passenger][:version]
      package "passenger",
        :ensure => (configuration[:passenger][:version]),
        :provider => :gem,
        :require => [ package('libcurl4-openssl-dev') ]
    end
  end

  # Build, install, and enable the passenger apache module. Please see the
  # <tt>passenger.conf.erb</tt> template for passenger configuration options.
  def passenger_apache_module
    # Install Apache2 developer library
    package "apache2-threaded-dev", :ensure => :installed

    file "/usr/local/src", :ensure => :directory

    exec "symlink_passenger",
      :command => 'ln -nfs `passenger-config --root` /usr/local/src/passenger',
      :unless => 'ls -al /usr/local/src/passenger | grep `passenger-config --root`',
      :require => [
        package("passenger"),
        file("/usr/local/src")
      ]

    # Build Passenger from source
    exec "build_passenger",
      :cwd => configuration[:passenger][:path],
      :command => 'sudo /usr/bin/ruby -S rake clean apache2',
      :unless => [
        "ls `passenger-config --root`/#{passenger_lib_dir}/apache2/mod_passenger.so",
        "ls `passenger-config --root`/#{passenger_lib_dir}/ruby/ruby-*/passenger_native_support.so",
        "ls `passenger-config --root`/#{passenger_agents_dir}/PassengerLoggingAgent"
        ].join(" && "),
      :require => [
        package("passenger"),
        package("apache2-mpm-worker"),
        package("apache2-threaded-dev"),
        exec('symlink_passenger')
      ],
      :timeout => 108000

    load_template = "LoadModule passenger_module #{configuration[:passenger][:path]}/#{passenger_lib_dir}/apache2/mod_passenger.so"

    file '/etc/apache2/mods-available/passenger.load',
      :ensure => :present,
      :content => load_template,
      :require => [exec("build_passenger")],
      :notify => apache_notifies,
      :alias => "passenger_load"

    file '/etc/apache2/mods-available/passenger.conf',
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger.conf.erb')),
      :require => [exec("build_passenger")],
      :notify => apache_notifies,
      :alias => "passenger_conf"

    a2enmod 'headers', :notify => apache_notifies

    a2enmod 'passenger', :require => [exec("build_passenger"), file("passenger_conf"), file("passenger_load"), exec('a2enmod headers')]
  end

  # Creates and enables a vhost configuration named after your application.
  # Also ensures that the <tt>000-default</tt> vhost is disabled.
  def passenger_site
    site_file = "/etc/apache2/sites-available/#{configuration[:application]}"
    if ubuntu_trusty?
      file site_file,
        :ensure => :absent,
        :notify => apache_notifies
      file "/etc/apache2/sites-enabled/#{configuration[:application]}",
        :ensure => :absent,
        :notify => apache_notifies
      site_file = "#{site_file}.conf"
    end
    file site_file,
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger.vhost.erb')),
      :notify => apache_notifies,
      :alias => "passenger_vhost",
      :require => exec("a2enmod passenger")

    a2dissite '000-default', :require => file("passenger_vhost")
    a2ensite configuration[:application], :require => file("passenger_vhost")
  end

  def passenger_configure_gem_path
    configure(:passenger => {})
    if configuration[:passenger][:enterprise]
      raise "You must define a version for passenger enterprise in moonshine.yml" if configuration[:passenger][:version].blank?
      configure(:passenger => {:path => "#{Gem.dir}/gems/passenger-enterprise-server-#{configuration[:passenger][:version]}"})
    elsif configuration[:passenger][:version].nil? || configuration[:passenger][:version] == :latest
      configure(:passenger => { :path => "#{Gem.dir}/gems/passenger-#{BLESSED_VERSION}" })
    elsif configuration[:passenger][:version]
      configure(:passenger => { :path => "#{Gem.dir}/gems/passenger-#{configuration[:passenger][:version]}" })
    end
  end

private

  def passenger_major_version
    return @major_version unless @major_version.nil?
    version_string = configuration[:passenger][:version] || BLESSED_VERSION
    @major_version = version_string.split('.').first.to_i
  end

  def passenger_minor_version
    return @minor_version unless @minor_version.nil?
    version_string = configuration[:passenger][:version] || BLESSED_VERSION
    @minor_version = version_string.split('.')[1].to_i
  end

  def passenger_patch_version
    return @patch_version unless @patch_version.nil?
    version_string = configuration[:passenger][:version] || BLESSED_VERSION
    @patch_version = version_string.split('.')[2].to_i
  end

  def passenger_lib_dir
    if (passenger_major_version > 4) || (passenger_major_version == 4 && passenger_minor_version > 0) || (passenger_major_version == 4 && passenger_minor_version == 0 && passenger_patch_version >= 6 )
      'buildout'
    elsif (passenger_major_version == 3 && passenger_minor_version >= 9) || (passenger_major_version == 4 && passenger_minor_version == 0 && passenger_patch_version <= 5 )
      'libout'
    else
      'ext'
    end
  end

  def passenger_agents_dir
    if (passenger_major_version > 4) || (passenger_major_version == 4 && passenger_minor_version > 0) || (passenger_major_version == 4 && passenger_minor_version == 0 && passenger_patch_version >= 6 )
      "#{passenger_lib_dir}/agents"
    else
      'agents'
    end
  end

  def supports_passenger_buffer_response?
    if configuration[:passenger][:version]
      passenger_major_version >= 4 || (passenger_major_version >=3 && passenger_minor_version > 0) || (passenger_major_version >= 3 && passenger_minor_version >= 0 && passenger_patch_version >= 11)
    else # blessed version does support it
      true
    end
  end

  def passenger_config_boolean(key, default = true)
    if key.nil?
      default ? 'On' : 'Off'
    else
      ((!!key) == true) ? 'On' : 'Off'
    end
  end

end
