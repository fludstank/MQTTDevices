# MQTTDevices
SmartThings Edge driver for creating MQTT-connected devices.  These devices will update their states based on MQTT messages.  No cloud connection is used, so everything is executed locally.

Currently supported device types:  switch, button, contact, motion, alarm, dimmer, vibration, lock, presence, sound, moisture, temperature.  More can be added - just ask!

Switch, button, alarm, dimmer, lock, and temperature devices can also be configured to publish MQTT messages when state changes from within SmartThings (i.e., manually via mobile app or automations).

## Use Cases
If you have a device or application that publishes messages using MQTT, then you can use this driver to easily integrate into SmartThings.  
If you have a device or application that responds to messages from MQTT, then you can use this driver to initiate MQTT messages from supported SmartThings device types such as switches or momentary buttons.

## Pre-requisites
* SmartThings Hub
* MQTT broker such as [Mosquitto](https://mosquitto.org/)

## Installation / Configuration
Install driver using [this channel invite link](https://bestow-regional.api.smartthings.com/invite/Q1jP7BqnNNlL).  Enroll your hub and choose "MQTT Devices V1" from the list of drivers to install.

Once available on your hub, use the SmartThings mobile app to initiate an *Add device / Scan for nearby devices*. A new device called 'MQTT Device Creator' will be found in your 'No room assigned' room.  Open the device and go to the device Settings menu (3 vertical dot menu in upper right corner of Controls tab).  Provide the username and password (if required) for your MQTT broker, and the IP address of the MQTT broker.  Return to the Controls screen and the Status field there will indicate if the driver is now connected to the MQTT broker.

## Usage
### MQTT Device Creator device
This 'master' device is used to create the desired device types (e.g. switch, button, contact, motion, etc.).  Simply go to the Controls screen and tap the top button labeled 'Select & Create MQTT Device'.  Choose the device type and a new device will be created and found in the 'No room assigned' room.

The MQTT Device Creator will also display a list of the MQTT topics that are currently subscribed to across all created devices.

### Configuration of created MQTT devices (switch, button, contact, motion, alarm, dimmer)
Once a device is created using the master device, go to the respective device Settings screen to configure the MQTT topic for the device to respond to, as well as other optional preferences:

* **Subscribe Topic**: MQTT topic in the form of xxxx/xxxx that this device will respond to
* **Expected Message format**: Select *string* if MQTT message data format is a simple string, or *json* if the message data format is json formatted
* **JSON Key**: If message format is json, then provide the element key containing the value to be inspected
* **Values**: set of expected values to be received representing each of the valid states for the device type; note this is case sensitive (*n/a for Dimmer*)
* **Publish xxxx State Changes**: Enable to have state changes published when a switch/button/alarm/dimmer state is activated from within SmartThings
* **Publish Topic**: If publish state changes is enabled, then provide here the MQTT topic to publish the state change to
* **Publish QoS**: Select 0, 1, or 2 for the MQTT Quality of Service (QoS) level to use when publishing the state change

The last three options listed above (Publish-related) are available only for switch, button, alarm, and dimmer.

Once the device is successfully subscribed to the broker, the status field on the device Controls screen will show 'Subscribed' and the list shown in the master device will be updated with the topic.

### Additional notes
* All device state changes are available for automations
* Multiple devices can be subscribed to the same topic
* Changes to broker authentication or IP will result in automatic reconnect
* Changes to device subscribe topic will result in prior topic automatically being unsubscribed and the new topic subscribed-to
* Monitor the status fields on the device Controls screens to confirm connection & subscription status
* Refresh buttons need only be used to force re-connection or re-subscribe in the event of a problem
* Unique broker per device is not supported
* Momentary button devices support 4 types of received messages: button pressed, double-push, triple-push, and button held
* Values published: For Switch, the respective ON/OFF values configured in Settings are sent; for Button the button PRESSED value configured in Settings is sent
