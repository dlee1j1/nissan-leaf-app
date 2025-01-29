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
