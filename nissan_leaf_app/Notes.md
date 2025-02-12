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
  - got pretty far today - now can get all the way to the OBD port, we are writing to it and we can reliably read from it.
  - Unfortunately, we are not getting multi-frame CAN data back but rather, we are just getting a single frame. Not sure what is wrong.

- 2025-02-01

  - verified that multi-frame CAN data is not working either using LightBlue app. Also setting ATCAF1 causes the device to send back an error message.
  - looking up HA logs - I see that they use a mystery command to test out the CAN bus before trying to get the data. IF the mystery command fails then I suppose it just means that the Battery Management system is not running???

- 2025-02-08
  - lots of progress. A few insights:
    - CAN protocol parsing is in protocol_can.py
    - it deals with the CAN bus frames. Put that into OBDCommand
    - multi-frames need to be setup by AT commands send as part of the header call. The AI didn't do that part when it copied over the \_set_header command.
    - there's also flow control AT command (AT3000) or something like that that is done during initialization that was buried in the obd.py code instead of the ELM 327 code
    - not sure exactly why the single frame parsing between the PYthon code and the DART code is off by one. I can't see where that extra offset is done in python
- 2025-02-10

  - got the multi-frame CAN data working. Also added a testing page. Now we get the SOH and SOC data back.
  - next step - add tests

- 2025-02-11
  - added tests
  - finished copying over all the commands
  - fixed up the UI to display everything
  - SOC seems a little off but close = the car is showing 100% but we are reading 93%
  - pressure readings are wrong
    - 7 63 04 62 0E 28 00 - rl
    - 7 63 04 62 0E 27 00 - rr
    - 7 63 04 62 0E 26 00 - fl
    - 7 63 04 62 0E 25 00 - fr
  - range remaining is off
    - 7 63 10 0D 62 0E 24 00 18 42
    - 7 63 21 08 80 02 00 00 00 00
      [62 0E 24 00 18 42 08 80 02 ]
      Byte Pair Analysis (overlapping):
      ***
      Bytes | Unsigned | Signed | Binary
      ***
      62 0E | 25102 | 25102 | 0110001000001110
      0E 24 | 3620 | 3620 | 0000111000100100
      24 00 | 9216 | 9216 | 0010010000000000
      00 18 | 24 | 24 | 0000000000011000
      18 42 | 6210 | 6210 | 0001100001000010
      42 08 | 16904 | 16904 | 0100001000001000
      08 80 | 2176 | 2176 | 0000100010000000
      80 02 | 32770 | -32766 | 1000000000000010
