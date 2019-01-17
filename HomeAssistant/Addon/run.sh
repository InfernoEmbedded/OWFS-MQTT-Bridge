#!/bin/bash
# ==============================================================================
# Community Hass.io Add-ons: OWFS to MQTT Gateway
# Bridges OWFS (with suuport for Inferno Embedded Softdevices) to MQTT
# ==============================================================================
# shellcheck disable=SC1091

set -e

CONFIG_PATH=/data/options.json

conf() {
	jq --raw-output .$1 $CONFIG_RATH
}

owserverArgs=$(conf owserver_args)
sensorPeriod=$(conf sensor_period)
switchPeriod=$(conf switch_period)
mqttHost=$(conf mqtt_host)
mqttPort=$(conf mqtt_port)
mqttUsername=$(conf mqtt_username)
mqttPassword=$(conf mqtt_password)

cat << EOF >/tmp/ha.toml
[general]
	timezone="Australia/Sydney"
	discovery_prefix="homeassistant"

[1wire]
	host="localhost"
	port=4304
	timeout=5 # seconds, will reconnect after this if no response
	sensor_period=$sensor_period # seconds
	switch_period=$switch_period # seconds
	debug=true

[mqtt]
	host="$mqtt_host"
	port=$mqtt_port
	username="$mqtt_username"
	password="$mqtt_password"
EOF

echo Using the following config:
cat /tmp/ha.toml

echo Starting owserver
/opt/owfs/bin/owserver $owserver_args

echo Starting Daemon
HA_CONFIG=/tmp/ha/toml /opt/OWFS-MQTT-Bridge/ha-daemon.pl

