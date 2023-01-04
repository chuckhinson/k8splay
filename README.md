This project was created to simpifly/automate some of the tasks in the labs in Kubernetes The Hard Way.  In particular, I followed the fork at https://github.com/prabhatsharma/kubernetes-the-hard-way-aws which is a fork of Kelsey Hightower's original project, but modified to work with AWS instead of GCP.

There are two primary things of value in this project:
- a terraform module that provisions all of the compute and network resources in AWS
- a script that perpares a bunch of files that need to be created an copied to the servers
These two things automate most of the stuff in the first six sections/labs of Kubernetes The Hard Way and get you ready to start the Bootstrapping the etcd Cluster lab.

I did this mainly because I was expecting to be tearing down and recreating clusters when needed rather than leaving the cluster up and running all the time, but also because I wanted to learn terroform.


The basic process is as follows:
1. Install aws cli, terraform, kubectl and tmux
2. Setup your .aws/config and credentials and ensure you can run aws cli commands
3. git clone this project
4. In the project directory, create terraform.tfvars with the following single line:
    1. `mgmt_server_cidr_block = "xx.xx.xx.xx/32"`
    2. (replace xx.xx.xx.xx with your external ip address)
5. run terrform apply to create your aws compute and network resources
6. run the prepare-files.sh script to create and upload some certificates and configuration files that you'll need
7. Follow the instructions in Kubenetes the Hard Way starting with the Bootstrapping the etcd Cluster and continuing to the end (note that you can skip the Provisioning Pod Network Routes as the terrform takes care of that already)

Note that I ran into a couple of gotchas.

First, instead of using 10.0.0.0/16 as my VPC CIDR block, I used 10.2.0.0/16 so as not to conflict with something else I already had going in my AWS account.  This is mostly not a big deal except that some of the labs include 10.0.x.x addresses in the code snippets that you'll copy/paste and you have to be sure to change them to 10.2.x.x.

The second gotcha is that I ran into a problem when deploying the worker nodes where containerd was unable to create pods due to an issue (I think) with cgroup2 compatability.  I'm guessing that the combination of using an older k8s distro (the labs use 1.21) and the latest ubuntu (22.04) caused the conflict.  In any case, editing the containerd config file seemed to resolved the problem.  Specifically,
the /etc/containerd/config.toml file provided in the lab:
```
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runc"
      runtime_root = ""
```
needs to be edited so that it just has
```
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
```

