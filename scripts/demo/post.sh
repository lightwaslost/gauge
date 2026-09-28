#!/usr/bin/env bash
# Sends a demo command to a Gauge launched with --demo. Example: post.sh section:cpu
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('app.gauge.demo', '$1', \$(), true)" >/dev/null
