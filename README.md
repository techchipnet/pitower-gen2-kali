# PiTower Gen2 for Kali Linux

Set up the Elecrow PiTower Gen2 LCD, RGB lighting and shutdown button on a Raspberry Pi 5 running Kali Linux ARM64.

## Install

Download and extract this repository, then open a terminal in its folder:

```bash
sudo bash setup-pitower-kali.sh
```

Once installation finishes, reboot:

```bash
sudo reboot
```

The LCD, RGB lights and button service will start automatically after reboot. Internet access is required during setup.

## Check status

```bash
sudo bash setup-pitower-kali.sh status
```

The LCD shows system statistics, not the Kali desktop. The button shuts down Linux; automatic case power-cut is not included.

## Credits

Based on [Elecrow's PiTower Gen2 project](https://github.com/Elecrow-RD/PiTower_Gen2), with Kali installation fixes. This is an unofficial community installer.

## License

The installer is MIT licensed. Downloaded upstream software and assets retain their original licenses.
