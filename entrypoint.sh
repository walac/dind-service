#!/bin/bash -ve

# Exit on errors
set -e;

# Ensure that all nodes in /dev/mapper correspond to mapped devices currently
# loaded by the device-mapper kernel driver
dmsetup mknodes

# First, make sure that cgroups are mounted correctly.
CGROUP=/sys/fs/cgroup
: {LOG:=stdio}

[ -d $CGROUP ] ||
  mkdir $CGROUP

mountpoint -q $CGROUP ||
  mount -n -t tmpfs -o uid=0,gid=0,mode=0755 cgroup $CGROUP || {
    echo "Could not make a tmpfs mount. Did you use --privileged?"
    exit 1
  }

if [ -d /sys/kernel/security ] && ! mountpoint -q /sys/kernel/security
then
    mount -t securityfs none /sys/kernel/security || {
        echo "Could not mount /sys/kernel/security."
        echo "AppArmor detection and --privileged mode might break."
        exit 1
    }
fi

# Mount the cgroup hierarchies exactly as they are in the parent system.
for SUBSYS in $(cut -d: -f2 /proc/1/cgroup)
do
        [ -d $CGROUP/$SUBSYS ] || mkdir $CGROUP/$SUBSYS
        mountpoint -q $CGROUP/$SUBSYS ||
                mount -n -t cgroup -o $SUBSYS cgroup $CGROUP/$SUBSYS

        # The two following sections address a bug which manifests itself
        # by a cryptic "lxc-start: no ns_cgroup option specified" when
        # trying to start containers withina container.
        # The bug seems to appear when the cgroup hierarchies are not
        # mounted on the exact same directories in the host, and in the
        # container.

        # Likewise, on at least one system, it has been reported that
        # systemd would mount the CPU and CPU accounting controllers
        # (respectively "cpu" and "cpuacct") with "-o cpuacct,cpu"
        # but on a directory called "cpu,cpuacct" (note the inversion
        # in the order of the groups). This tries to work around it.
        [ $SUBSYS = cpuacct,cpu ] && ln -s $SUBSYS $CGROUP/cpu,cpuacct
done

# Note: as I write those lines, the LXC userland tools cannot setup
# a "sub-container" properly if the "devices" cgroup is not in its
# own hierarchy. Let's detect this and issue a warning.
grep -q :devices: /proc/1/cgroup || {
  echo "WARNING: the 'devices' cgroup should be in its own hierarchy."
  exit 1
}
grep -qw devices /proc/1/cgroup || {
  echo "WARNING: it looks like the 'devices' cgroup is not mounted."
  exit 1
}

# Now, close extraneous file descriptors.
pushd /proc/self/fd >/dev/null
for FD in *
do
  case "$FD" in
  # Keep stdin/stdout/stderr
  [012])
    ;;
  # Nuke everything else
  *)
    eval exec "$FD>&-"
    ;;
  esac
done
popd >/dev/null

# If a pidfile is still around (for example after a container restart),
# delete it so that docker can start.
rm -rf /var/run/docker.pid

# Start docker daemon with container arguments as docker daemon arguments
if [ "$LOG" == "file" ]; then
  docker -d -H unix:///var/run/docker.sock &>/var/log/docker.log "$@" &
elif [ "$LOG" == "pipe" ]; then
  docker -d -H unix:///var/run/docker.sock "$@" &
else
  echo 'The variables $LOG most be either "file" or "pipe"';
  exit 1;
fi

# Wait for docker socket to be ready
(( timeout = 60 + SECONDS ))
until docker info >/dev/null 2>&1; do
  if (( SECONDS >= timeout )); then
    echo 'Timed out trying to connect to internal docker host.' >&2
    exit 1;
    break
  fi
  sleep 1;
done
echo "docker daemon now ready for business";

# Start docker daemon socket proxy
exec npm start
