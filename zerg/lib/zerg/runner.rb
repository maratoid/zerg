#--

# Copyright 2014 by MTN Sattelite Communications
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#++

require 'awesome_print'
require 'fileutils'
require 'erb'
require 'rbconfig'

module Zerg
    class Runner

        def check_provider(driver, provider)
            if driver == "vagrant"
                if provider == "aws"
                    aws_pid = Process.spawn("vagrant plugin list | grep vagrant-aws")
                    Process.wait(aws_pid)

                    if $?.exitstatus != 0
                        aws_pid = Process.spawn("vagrant plugin install vagrant-aws")
                        Process.wait(aws_pid)
                        abort("ERROR: vagrant-aws installation failed!") unless $?.exitstatus == 0
                    end
                elsif provider == "libvirt"
                    abort("ERROR: libvirt is only supported on a linux host!") unless /linux|arch/i === RbConfig::CONFIG['host_os']
                    
                    libvirt_pid = Process.spawn("vagrant plugin list | grep vagrant-libvirt")
                    Process.wait(libvirt_pid)

                    if $?.exitstatus != 0
                        libvirt_pid = Process.spawn("vagrant plugin install vagrant-libvirt")
                        Process.wait(libvirt_pid)
                        abort("ERROR: vagrant-libvirt installation failed! Refer to https://github.com/pradels/vagrant-libvirt to install missing dependencies, if any.") unless $?.exitstatus == 0
                    end
                end
            end
        end

        # cross platform way of checking if command is available in PATH
        def self.which(cmd)
            exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
            ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
                exts.each { |ext|
                exe = File.join(path, "#{cmd}#{ext}")
                return exe if File.executable? exe
                }
            end
          return nil
        end

        def process(taskname, task, debug)
            puts ("Will perform task #{taskname} with contents:\n #{task.ai}")

            # render driver template
            renderer = DriverRenderer.new(
                task["vm"], 
                taskname, 
                task["instances"], 
                task["synced_folders"], 
                task["tasks"])
            
            renderer.render

            # do we need additional plugins?
            task["tasks"].each { |task|
                if task["type"] == "chef_client" || task["type"] == "chef_solo"
                    omnibus_pid = Process.spawn("vagrant plugin list | grep vagrant-omnibus")
                    Process.wait(omnibus_pid)

                    if $?.exitstatus != 0
                        omnibus_pid = Process.spawn("vagrant plugin install vagrant-omnibus")
                        Process.wait(aws_pid)
                        abort("ERROR: vagrant-omnibus installation failed!") unless $?.exitstatus == 0
                    end
                    break;
                end
            }


            run(taskname, task["vm"]["driver"]["drivertype"], task["vm"]["driver"]["providertype"], task["instances"], (task["vm"]["keepalive"] == nil) ? false : task["vm"]["keepalive"], debug)
        end

        def cleanup(taskname, task, debug)
            puts ("Will cleanup task #{taskname}...")

            # TODO: generalize for multiple drivers
            # render driver template
            renderer = DriverRenderer.new(
                task["vm"], 
                taskname, 
                task["instances"],
                task["synced_folders"],  
                task["tasks"])        
            renderer.render

            check_provider(task["vm"]["driver"]["drivertype"], task["vm"]["driver"]["providertype"])

            # run vagrant cleanup
            debug_string = (debug == true) ? " --debug" : ""
            
            for index in 0..task["instances"] - 1
                cleanup_pid = Process.spawn(
                    {
                        "VAGRANT_CWD" => File.join("#{Dir.pwd}", ".hive", "driver", task["vm"]["driver"]["drivertype"], taskname),
                        "VAGRANT_DEFAULT_PROVIDER" => task["vm"]["driver"]["providertype"]
                    },
                    "vagrant destroy zergling_#{index} --force#{debug_string}")
                Process.wait(cleanup_pid)
                abort("ERROR: vagrant failed!") unless $?.exitstatus == 0
            end

            cleanup_pid = Process.spawn(
                {
                    "VAGRANT_CWD" => File.join("#{Dir.pwd}", ".hive", "driver", task["vm"]["driver"]["drivertype"], taskname)
                },
                "vagrant box remove zergling_#{taskname}_#{task["vm"]["driver"]["providertype"]}#{debug_string} #{task["vm"]["driver"]["providertype"]}")
            Process.wait(cleanup_pid)
        end

        def halt(taskname, driver, provider, instances, debug)
            puts("Halting all vagrant virtual machines...")
            debug_string = (debug == true) ? " --debug" : ""  

            # halt all machines
            halt_pid = nil
            for index in 0..instances - 1
                halt_pid = Process.spawn(
                    {
                        "VAGRANT_CWD" => File.join("#{Dir.pwd}", ".hive", "driver", driver, taskname),
                        "VAGRANT_DEFAULT_PROVIDER" => "#{provider}"
                    },
                    "vagrant halt zergling_#{index}#{debug_string}")
                Process.wait(halt_pid)
                abort("ERROR: vagrant halt failed on machine zergling_#{index}!") unless $?.exitstatus == 0
            end
        end

        def run(taskname, driver, provider, instances, keepalive, debug)
            check_provider(driver, provider)

            debug_string = (debug == true) ? " --debug" : ""                

            # bring up all of the VMs first.
            puts("Starting vagrant in #{File.join("#{Dir.pwd}", ".hive", "driver", driver, taskname)}")
            for index in 0..instances - 1
                create_pid = Process.spawn(
                    {
                        "VAGRANT_CWD" => File.join("#{Dir.pwd}", ".hive", "driver", driver, taskname)
                    },
                    "vagrant up zergling_#{index} --no-provision --provider=#{provider}#{debug_string}")
                Process.wait(create_pid)
                
                if $?.exitstatus != 0
                    puts "ERROR: vagrant failed while creating one of the VMs. Will clean task #{taskname}:"
                    self.class.clean(taskname, debug)
                    abort("ERROR: vagrant failed!")
                end
            end

            puts("Running tasks in vagrant virtual machines...")
            # and provision them all at once (sort of)
            provisioners = Array.new
            provision_pid = nil
            for index in 0..instances - 1
                provision_pid = Process.spawn(
                    {
                        "VAGRANT_CWD" => File.join("#{Dir.pwd}", ".hive", "driver", driver, taskname),
                        "VAGRANT_DEFAULT_PROVIDER" => "#{provider}"
                    },
                    "vagrant provision zergling_#{index}#{debug_string}")
                provisioners.push({:name => "zergling_#{index}", :pid => provision_pid})
            end

            # wait for everything to finish...
            errors = Array.new
            lock = Mutex.new
            provisioners.each { |provisioner| 
                Thread.new { 
                    Process.wait(provisioner[:pid]); 
                    lock.synchronize do
                        errors.push(provisioner[:name]) unless $?.exitstatus == 0    
                    end
                }.join 
            }

            if keepalive == false
                halt(taskname, driver, provider, instances, debug)
            else
                puts "Will leave instances running."
            end

            abort("ERROR: Finished with errors in: #{errors.to_s}") unless errors.length == 0
            puts("SUCCESS!")
        end

        def self.rush(task, debug)
            abort("ERROR: Vagrant not installed!") unless which("vagrant") != nil

            # load the hive first
            Zerg::Hive.instance.load

            puts "Loaded hive. Looking for task #{task}..."
            abort("ERROR: Task #{task} not found in current hive!") unless Zerg::Hive.instance.hive.has_key?(task) 

            # grab the current task hash and parse it out
            runner = Runner.new
            runner.process(task, Zerg::Hive.instance.hive[task], debug);
        end

        def self.halt(task, debug)
            abort("ERROR: Vagrant not installed!") unless which("vagrant") != nil

            # load the hive first
            Zerg::Hive.instance.load

            puts "Loaded hive. Looking for task #{task}..."
            abort("ERROR: Task #{task} not found in current hive!") unless Zerg::Hive.instance.hive.has_key?(task) 

            # halt!
            runner = Runner.new
            runner.halt(task, Zerg::Hive.instance.hive[task]["vm"]["driver"]["drivertype"], Zerg::Hive.instance.hive[task]["vm"]["driver"]["providertype"], Zerg::Hive.instance.hive[task]["instances"], debug)
            puts("SUCCESS!")
        end

        def self.clean(task, debug)
            abort("ERROR: Vagrant not installed!") unless which("vagrant") != nil

            # load the hive first
            #Zerg::Hive.instance.load

            #puts "Loaded hive. Looking for task #{task}..."
            #abort("ERROR: Task #{task} not found in current hive!") unless Zerg::Hive.instance.hive.has_key?(task) 

            #runner = Runner.new
            #runner.cleanup(task, Zerg::Hive.instance.hive[task], debug);
            #puts("SUCCESS!")

            pmgr = ZergGemPlugin::Manager.instance
            pmgr.load
            vagrant = pmgr.create("/driver/vagrant")
            vagrant.clean
        end
    end
end