#!/bin/sh

log=grub-mkfont.log
font_list=fonts.lst

font_convert()
{
  size=$1
  namein=$2
  nameout=$3
  options=$4
  fnout="$nameout"_"$size".pf2
  grub-mkfont -v $options -s $size -o "pf2/$fnout" "ttf/$namein" | tee -a $log | grep "name" | xargs echo $fnout "->" >> $font_list
  echo -------------------- >> $log
}

rm -f $log
rm -f $font_list
rm -f pf2/*

# add "-r 0x0-0x7F" or "--ascii-bitmaps" option to save ascii characters only
font_convert 64 "AngelicWar.ttf" angelic_war
font_convert 48 "AngelicWar.ttf" angelic_war
font_convert 64 "Decibel_2.ttf" decibel
font_convert 48 "Decibel_2.ttf" decibel
font_convert 64 "FairyDustB.ttf" fairy_dust_b
font_convert 48 "FairyDustB.ttf" fairy_dust_b
font_convert 64 "leaf1.TTF" leaf_1
font_convert 48 "leaf1.TTF" leaf_1
font_convert 32 "leaf1.TTF" leaf_1
font_convert 24 "leaf1.TTF" leaf_1
font_convert 64 "Miama.ttf" miama
font_convert 48 "Miama.ttf" miama
font_convert 64 "Postit-Penscript.otf" post-it_pen_script
font_convert 48 "Postit-Penscript.otf" post-it_pen_script
font_convert 64 "Special Type.ttf" special_type
font_convert 48 "Special Type.ttf" special_type
font_convert 64 "Vtks black.ttf" vtks_black
font_convert 48 "Vtks black.ttf" vtks_black
font_convert 64 "when it rains.ttf" when_it_rains
font_convert 48 "when it rains.ttf" when_it_rains

font_convert 18 "ASENINE_.ttf" asenine
font_convert 18 "eurof35.ttf" eurofurence_light
font_convert 18 "Existence-Light.PFB" existence_light
font_convert 18 "rough_typewriter.otf" rough_typewriter
font_convert 18 "SECRCODE.TTF" secret_code

echo >> $log
echo >> $font_list

