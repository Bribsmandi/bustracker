import paho.mqtt.client as mqtt

def on_message(c, u, m):
    print(f'{m.topic}: {m.payload.decode()}')

c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
c.on_message = on_message
c.connect('broker.emqx.io', 1883)
c.subscribe('campus_arund/#')
c.loop_forever()
