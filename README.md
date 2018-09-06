# About

A set of terraform scripts and shell scripts used by kcmo.social to create a docker swarm running mastodon.
It supports one production environment and one staging environment as a subdomain.

Currently it is fixed on three manager nodes and requires setting up a custom image in digital ocean.  
If you're thinking of using this to start your own instance you should have some basic familiarity with 
or desire to learn:

* Digital ocean
* Terraform
* Docker
* Linux 

This is designed to be an easily scalable setup, it is not designed to be a wholly fault tolerant 
automatic scaling setup.  Postgres, Redis, and Traefik all run a single container on a single labeled 
node to avoid having to share data between nodes.  If one of those droplets goes down you'll still need 
to restore the data (but there are backups!)

Postgres and redis are constrained to run on a single labeled host.  They will create volumes for 
persistence.  If you want to move those sevices you must move those volumes too.


# Setup the prerequisites

Fork this repo so you can make changes for your environment.

The host computer will need a copy of `terraform` and `jq` installed.  
On OS X `jq` can be installed via Homebrew.

Update `staging/backend.tf` and `production/backend.tf`.  They are currently configured to use 
AWS's S3 and DynamoDB for remote state storage, but you could change this to use local storage if you'd like.
Just be sure not to check the statefile into a public repository because it will contain sensitive information.

You should now be able to run `terraform init` in `production` and in `staging`.

Edit `staging/main.tf` and `production/main.tf` becuse it's littered with environment specific information.  
Fill in what you can fix offhand and be prepared to return as you populate the images, keys, and buckets in 
Digital Ocean.

Copy the sample secrets file into each staging and production environment.

    cp secrets.auto.tfvars.example  production/secrets.auto.tfvars
    cp secrets.auto.tfvars.example  staging/secrets.auto.tfvars


Keep in mind that these are 'secret' as in they won't be checked into source control, but they may be 
visible in the terraform state files.  `do_token` and `aws_profile` are used by the default backend but
look in `mastodon_swarm/variables.tf` for a description of the others.  

To generate a set of keys for vapid to enable web push run the `generate_vapid_keys.rb` script

# Droplet Images
This uses a private image provisioned with the `custom_image/setup.sh` script.  The pre-built `docker-16-04` 
images from DO were using docker 17 and seemed to have stability issues.

To build your own, start up the smallest droplet available and run the setup script on the server.  
After everything has installed power down the server with `shutdown -h now` and use the digital ocean 
console to take a snapshot of the droplet.  When it's complete get a list of your custom images from the 
Digital Ocean API with something like:

    curl -X GET -H "Content-Type: application/json" -H "Authorization: Bearer SOME_TOKEN_HERE" "https://api.digitalocean.com/v2/images?page=1&private=true"
    
Find the image ID corresponding to your new image and set it in the `swarm_image` variable in each environment.


# Administration and Monitoring

Once the terraform has run successfully it will output the first manager node, for example 
manager-01.nyc1.kcmo.social.  It will leave a few files in the mastodon user's home account
for administering the mastodon stack.

It also runs Portainer for container monitoring and management and Traefik for SSL termination 
directing traffic to services in the cluster.  They both have management interfaces available
via SSH tunnels.

Start an SSH tunnel to a node with:

    ssh -N -L 9000:manager-02.nyc1.kcmo.social:9000 -L 8080:manager-02.nyc1.kcmo.social:8080 mastodon@manager-01.nyc1.kcmo.social

Then visit http://localhost:9000/#/home for docker swarm management.  Visit http://localhost:8080 for 
external HTTP traffic monitoring with Traefik.

To run rake commands ssh to manager-01 and invoke the command with:

    docker run --rm \
    --net mastodon_internal-net \
    --env-file mastodon.env \
    -e RAILS_ENV=production \
    tootsuite/mastodon:v2.4.4 \
    COMMAND_TO_RUN_HERE
    
For example, to make alice an admin ( See https://github.com/tootsuite/documentation/blob/master/Running-Mastodon/Administration-guide.md for more info)

    docker run --rm \
    --net mastodon_internal-net \
    --env-file mastodon.env \
    -e RAILS_ENV=production \
    -e USERNAME=alice \
    tootsuite/mastodon:v2.4.4 \
    rails mastodon:make_admin

You can also use the portainer interface to open a console on one of the containers running 
mastodon image and run the same rails commands.

# Security

This terraform will store sensitive information in the tfstate.  You should not check this into source control.  
If you do choose to store it, make sure that it is in a secure location.  If you are storing it in S3 that 
means the bucket IS NOT PUBLIC, ideally encrypted at rest with access logs.  
See https://tosbourn.com/hiding-secrets-terraform/ for more information.

Access to the droplets is controlled by SSH keys and inbound SSH IP address filters.  Only the mastodon web 
services are exposed externally.  Portainer is a powerful container management interface and it is not 
pre-configured with a password, but it is only available via ssh tunneling.

# First time startup

When starting up a cluster for the first time the scripts have a lot to do.  If a step fails, it is 
safe to re-run `terraform apply` until it completes.

The first time you apply the terraform it will compile the assets into a volume on each host.  
Once it is complete teraform will start the mastodon stack.

When the terraform apply is complete you will need to set up the database.  SSH to a manager and run:

    docker run --rm \
    --net mastodon_internal-net \
    --env-file mastodon.env \
    -e RAILS_ENV=production \
    -e SAFETY_ASSURED=1 \
    tootsuite/mastodon:v2.4.4 \
    rails db:setup
    

# Making changes

If you change the mastodon environment, variables used in the environment, or the mastodon stack just re-run
`terraform apply`.  Beware that the assets are not recompiled on each change.  

You can also ssh to a server and do it manually, use portainer, or force a redeploy by tainting the 
terraform resource with `terraform taint -module=mastodon_swarm null_resource.deploy_mastodon` and 
running `terraform apply`.

If asset compliation has changed you need to restart the web service AND the sidekiq service.  You can use 
portainer or run

    docker service scale mastodon_web=0
    docker service scale mastodon_sidekiq=0
    docker service scale mastodon_web=2
    docker service scale mastodon_sidekiq=1
    
to force a restart.  You can also use the portainer interface if you have an ssh tunnel up by 
visiting http://localhost:9000/#/services, checking off the two services, clicking the restart button.

To recompile the assets taint the provisioner with 
`terraform taint -module=mastodon_swarm null_resource.deploy_mastodon_assets` and run`terraform apply`.  

# Backups

Backups of named docker volumes are scheduled to occur nightly.  This includes postgres, redis, traefik, 
and any user data that was uploaded locally insted of to remote object storage (like Digital Ocean Spaces).  
Backups are kept for 21 days, full backups every 7 days.  Postgres is backed up as a full sql dump.  The 
backup engine is Duplicity, and while it is possible to restore manually it's recommended to use the duplicity
tool for restores.