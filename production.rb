require "bundler/capistrano"

# this should be the the server address or ip you'll be deploying to
server "your-ip-address", :web, :app, :db, primary: true

# set RAILS_ENV
set :rails_env, :production

# the name of your application
set :application_name, "your_application_name"

# the domain you'll be deploying your application to
set :application_domain, "domain_your_deploying_to"

# your application name which is used in file paths is a combination
# of the application name and the rails environment
set :application, "#{application_name}_#{rails_env}"

# the user to deploy as
set :user, "deploy"

# the directory to deploy to
set :deploy_to, "/home/#{user}/apps/#{application}"
set :deploy_via, :remote_cache
set :use_sudo, false

# the details of the source control where the codebase should be
# retrieved from from
set :scm, "git"
set :repository, "your-git-repo"
set :branch, "master"

# make sure rbenv ruby is available
set :default_environment, {
      'PATH' => "/usr/local/rbenv/shims:/usr/local/rbenv/bin:$PATH"
    }

# make sure if a password is requested we're able to enter it
default_run_options[:pty] = true

# forward commands through our local ssh session. This means we
# don't need to to give the server direct access to the git repo
ssh_options[:forward_agent] = true

# once the deploy is complete, run a cleanup to remove everything
# other than the last 5 releases.
after "deploy", "deploy:cleanup"

# define the control commands for nginx so capistrano can
# automatically restart the server after a deploy
namespace :deploy do
  %w[start stop restart].each do |command|
    desc "#{command} unicorn server"
    task command, roles: :app, except: {no_release: true} do
      run "/etc/init.d/unicorn_#{application} #{command}"
    end
  end

  # define the steps needed to initially setup the application
  task :setup_config, roles: :app do
    # make the config dir if it doesn't already exist
    run "mkdir -p #{shared_path}/config"

    # take the erb config files, apply our local variables to them and then
    # copy them to the shared directory

    # create a nginx virtual host
    template "config/deploy/#{rails_env}_resources/nginx.conf.erb", "#{shared_path}/config/nginx.conf"
    # define a control script for this applications unicorn workers
    template "config/deploy/#{rails_env}_resources/unicorn_init.sh.erb", "#{shared_path}/config/unicorn_init.sh"
    # define this applications unicorn configuration
    template "config/deploy/#{rails_env}_resources/unicorn.rb.erb", "#{shared_path}/config/unicorn.rb"

    # make the unicorn init script executable
    sudo "chmod +x #{shared_path}/config/unicorn_init.sh"

    # link the config files to the shared config
    sudo "ln -nfs #{shared_path}/config/nginx.conf /etc/nginx/sites-enabled/#{application}"
    sudo "ln -nfs #{shared_path}/config/unicorn_init.sh /etc/init.d/unicorn_#{application}"

    # create an example database.yml file
    template "config/deploy/#{rails_env}_resources/database.sample.yml.erb", "#{shared_path}/config/database.yml"

    # remind us that these config file need editing
    puts "Now edit the config files in #{shared_path}."
  end

  # once the standard setup commands have competed, run our setup_config task
  # defined above.
  after "deploy:setup", "deploy:setup_config"

  # For any config files normally located within the rails app (generally config/)
  # these need to be created as symlinks to the ones put in shared on deploy:config
  task :symlink_config, roles: :app do
    run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
  end
  after "deploy:finalize_update", "deploy:symlink_config"

  # make sure we're deploying what we think we're deploying. If the current local
  # branch isn't the same as the remote branch to deploy from, throw an error and
  # stop the deploy
  desc "Make sure local git is in sync with remote."
  task :check_revision, roles: :web do
    unless `git rev-parse HEAD` == `git rev-parse origin/#{branch}`
      puts "WARNING: HEAD is not the same as origin/#{branch}"
      puts "Run `git push` to sync changes."
      exit
    end
  end
  before "deploy", "deploy:check_revision"

  # execute our custom asset compilation script
  after 'deploy:update_code', 'assets:precompile'
end

# take advantage of the fact our local machine probably compiles assets faster
# than the remote server. Compile assets locally then rsync them to the remote
# server. Then remove them locally so they don't end up in version control and
# override the dynamically compiled ones.
namespace :assets do
  desc "Precompile assets locally and then rsync to app servers"
  task :precompile, :only => { :primary => true } do
    run_locally "bundle exec rake assets:precompile;"
    servers = find_servers :roles => [:app], :except => { :no_release => true }
    servers.each do |server|
      run_locally "rsync -av ./public/assets/ #{user}@#{server}:#{release_path}/public/assets/;"
    end
    run_locally "rm -rf public/assets"
  end
end

