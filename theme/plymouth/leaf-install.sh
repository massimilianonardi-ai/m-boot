sudo rm -r /lib/plymouth/themes/leaf
sudo cp -r leaf /lib/plymouth/themes
sudo update-alternatives --install /lib/plymouth/themes/default.plymouth default.plymouth /lib/plymouth/themes/leaf/leaf.plymouth 100
sudo update-alternatives --config default.plymouth
sudo update-initramfs -u

