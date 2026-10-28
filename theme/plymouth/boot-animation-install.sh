sudo rm -r /lib/plymouth/themes/boot-animation
sudo cp -r boot-animation /lib/plymouth/themes
sudo update-alternatives --install /lib/plymouth/themes/default.plymouth default.plymouth /lib/plymouth/themes/boot-animation/boot-animation.plymouth 100
sudo update-alternatives --config default.plymouth
sudo update-initramfs -u

