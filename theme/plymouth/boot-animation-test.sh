sudo rm -r /lib/plymouth/themes/boot-animation
sudo cp -r boot-animation /lib/plymouth/themes
sudo ./plymouth-test.sh 20

