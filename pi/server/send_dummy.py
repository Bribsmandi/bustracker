import paho.mqtt.publish as publish
publish.single('campus_arund/bus/bus1/gps', payload='test', hostname='broker.emqx.io', port=1883)

