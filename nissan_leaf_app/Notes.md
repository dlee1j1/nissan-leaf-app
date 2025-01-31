- 2025-01-28

  - got flutter working
  - Bluetooth testing is challenging
    - Chrome support for bluetooth is limited - i.e., need to select for it to show up. Doesn't read Bluetooth services
    - Running inside the dev container has issues with bluetooth pass through from Windows to the container, and likely with Windows to the WSL VM
    - installed Bluestacks emulator but it doesn't support bluetooth
  - In addition, X server in Windows doesn't support shading so running flutter inside the container and using X to display won't work
  - Conclusion

    - probably need to set up a couple physical devices - one IOS and another android even to just test simple bluetooth connectivity. Think we should do this one since we have the devices available.
    - alternatively, we can buy a USB dongle and either create an android VM or somehow thread the USB port to the container

  - Update - 5:26PM

    - I've got the flutter app working in the container and attach to the phone
    - Needed to put the device into developer mode and enable USB debugging (USB Debugging under developer options in System settings)
    - phone scans bluetooth but can't find the ODB device yet

  - Update - 10:07PM
    - flutter app now finds the ODB device. Time to start reading data from it.

- 2025-01-29

  - we have the flutter app showing debugging log in the app
  - however it seems like we are not actually connecting. Need to check that
  - Update - 11:26 AM - got it "connected" but ATZ command returns an A instead of OK

- 2025-01-30

  - we have flutter app connected to the car and we have AT commands working
  - effectively, we have gotten to the OBD BLE device
  - we now need to be able to send commands to the actual car - i.e., the OBD port itself
  - Not sure if we should send the bytes as ASCII text or do we push out and read Bytes

- 2025-01-31
  - big breakthrough last night. figured out the ODB commands.
  - Turns out you need to send and AT header command followed by the data specification. The code in the reference implementation was just a little opaque
  - built out the ODB command module
  - testing this morning has some issue with the ATZ command timing out. I see the > coming back so I don't know why it is not seeing it.
