#!/bin/bash -e
AUTHOR="Akgnah <1024@setq.me>"
VERSION="0.10.0"
SCRIPT_NAME=`basename $0`
ROOTFS_MOUNT=/tmp/rootfs
ROOTFS_PATH=/tmp/rootfs.img
DEVICE=/dev/$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p' | cut -b 1-7)


if [ `id -u` != 0 ]
then
    echo -e "${SCRIPT_NAME} needs to be run as root.\n"
    exit 1
fi


confirm() {
  if [ "$unattended" == "1" ]; then
    return 0
  fi
  printf "\n%s [Y/n] " "$1"
  read resp
  if [ "$resp" == "Y" ] || [ "$resp" == "y" ] || [ "$resp" == "yes" ]; then
    return 0
  fi
  if [ "$2" == "abort" ]; then
    echo -e "Abort.\n"
    exit 0
  fi
  if [ "$2" == "clean" ]; then
    rm "$3"
    echo -e "Abort.\n"
    exit 0
  fi
  return 1
}


commands="rsync parted gdisk resize-helper"
packages="rsync parted gdisk 96boards-tools-common"
need_packages=""

idx=1
for cmd in $commands
do
  if ! command -v $cmd > /dev/null; then
    pkg=$(echo "$packages" | cut -d " " -f $idx)
    printf "%-30s %s\n" "Command not found: $cmd", "package required: $pkg"
    need_packages="$need_packages $pkg"
  fi
  ((++idx))
done

if [ "$need_packages" != "" ]; then
  confirm "Do you want to apt-get install the packages?" "abort"
  apt-get install -y --no-install-recommends $need_packages
fi


OLD_OPTIND=$OPTIND
while getopts "o:m:t:hu" flag; do
  case $flag in
    o)
      output="$OPTARG"
      ;;
    m)
      model="$OPTARG"
      ;;
    t)
      target="$OPTARG"
      ;;
    h)
      $OPTARG
      print_help="1"
      ;;
    u)
      $OPTARG
      unattended="1"
      ;;
  esac
done
OPTIND=$OLD_OPTIND


gen_partitions() {
  if [ "$model" == "rockpis" ]; then
    boot_size=229376
  else
    boot_size=1048576
  fi

  loader1_size=8000
  reserved1_size=128
  reserved2_size=8192
  loader2_size=8192
  atf_size=8192

  system_start=0
  loader1_start=64
  reserved1_start=$(expr ${loader1_start} + ${loader1_size})
  reserved2_start=$(expr ${reserved1_start} + ${reserved1_size})
  loader2_start=$(expr ${reserved2_start} + ${reserved2_size})
  atf_start=$(expr ${loader2_start} + ${loader2_size})
  boot_start=$(expr ${atf_start} + ${atf_size})
  rootfs_start=$(expr ${boot_start} + ${boot_size})
}


gen_image_file() {
  if [ "$output" == "" ]; then
    output=${PWD}/rockpi-backup-`date +%y%m%d-%H%M`.img
  else
    if [ "${output:(-4)}" == ".img" ]; then
      mkdir -p `dirname $output`
    else
      mkdir -p "$output"
      output=${output%/}/rockpi-backup-`date +%y%m%d-%H%M`.img
    fi
  fi

  rootfs_size=$(expr `df -P | grep /dev/root | awk '{print $3}'` \* 5 \/ 4 \/ 1024)
  dd if=/dev/zero of=${ROOTFS_PATH} bs=1M count=0 seek=$rootfs_size status=none

  img_rootfs_size=$(stat -L --format="%s" ${ROOTFS_PATH})
  gptimg_min_size=$(expr $img_rootfs_size + \( ${loader1_size} + ${reserved1_size} + ${reserved2_size} + ${loader2_size} + ${atf_size} + ${boot_size} + 35 \) \* 512)
  gpt_image_size=$(expr $gptimg_min_size \/ 1024 \/ 1024 + 2)

  dd if=/dev/zero of=${output} bs=1M count=0 seek=$gpt_image_size status=none

  parted -s ${output} mklabel gpt
  parted -s ${output} unit s mkpart loader1 ${loader1_start} $(expr ${reserved1_start} - 1)
  parted -s ${output} unit s mkpart loader2 ${loader2_start} $(expr ${atf_start} - 1)
  parted -s ${output} unit s mkpart trust ${atf_start} $(expr ${boot_start} - 1)
  parted -s ${output} unit s mkpart boot ${boot_start} $(expr ${rootfs_start} - 1)
  parted -s ${output} set 4 boot on
  parted -s ${output} -- unit s mkpart rootfs ${rootfs_start} -34s

  if [ "$model" == "rockpis" ]; then
    ROOT_UUID="614e0000-0000-4b53-8000-1d28000054a9"
  else
    ROOT_UUID="B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
  fi

  gdisk ${output} > /dev/null << EOF
x
c
5
${ROOT_UUID}
w
y
q
EOF
}


check_avail_space() {
  output_=${output}
  while true; do
    store_size=`df -BM | grep "$output_\$" | awk '{print $4}' | sed 's/M//g'`
    if [ "$store_size" != "" ] || [ "$output_" == "\\" ]; then
      break
    fi
    output_=`dirname $output_`
  done

  if [ $(expr ${store_size} - ${gpt_image_size}) -lt 64 ]; then
    rm ${ROOTFS_PATH}
    rm ${output}
    echo -e "No space left on ${output_}\nAborted.\n"
    exit 1
  fi

  tmp_size=`df -BM | grep "/\$" | awk '{print $4}' | sed 's/M//g'`

  if [ $(expr ${tmp_size} - ${gpt_image_size}) -lt 64 ]; then
    if [ $(expr ${store_size} - ${gpt_image_size} - ${gpt_image_size}) -lt 64 ]; then
      rm ${ROOTFS_PATH}
      rm ${output}
      echo -e "No space left on /tmp or ${output_}\nAborted.\n"
      exit 1
    else
      echo '--------------------'
      echo -e "No space left on /tmp, so ${SCRIPT_NAME} put a temporary rootfs.img in ${output_}"
      confirm "Do you want to continue?" "abort"
      mv ${ROOTFS_PATH} ${output_}/rootfs.img
      ROOTFS_PATH=${output_}/rootfs.img
    fi
  fi

  return 0
}


backup_image() {
  mkdir -p ${ROOTFS_MOUNT}
  mkfs.ext4 ${ROOTFS_PATH}
  mount -t ext4 ${ROOTFS_PATH} $ROOTFS_MOUNT

  rsync --force -rltWDEgop --delete --stats --progress \
  --exclude "$output" \
  --exclude '.gvfs' \
  --exclude '/dev' \
  --exclude '/media' \
  --exclude '/mnt' \
  --exclude '/proc' \
  --exclude '/run' \
  --exclude '/sys' \
  --exclude '/tmp' \
  --exclude 'lost\+found' \
  --exclude "$ROOTFS_MOUNT" \
  // $ROOTFS_MOUNT

  # special dirs
  for i in dev media mnt proc run sys boot; do
    if [ ! -d $ROOTFS_MOUNT/$i ]; then
      mkdir $ROOTFS_MOUNT/$i
    fi
  done

  if [ ! -d $ROOTFS_MOUNT/tmp ]; then
    mkdir $ROOTFS_MOUNT/tmp
    chmod a+w $ROOTFS_MOUNT/tmp
  fi

  sync
  umount $ROOTFS_MOUNT

  dd if=${DEVICE}p1 of=${output} seek=${loader1_start} conv=notrunc
  dd if=${DEVICE}p2 of=${output} seek=${loader2_start} conv=notrunc
  dd if=${DEVICE}p3 of=${output} seek=${atf_start} conv=notrunc
  dd if=${DEVICE}p4 of=${output} conv=notrunc seek=${boot_start} status=progress
  dd if=${ROOTFS_PATH} of=${output} conv=notrunc,fsync seek=${rootfs_start} status=progress

  rm ${ROOTFS_PATH}

  echo "Backup done, backup file is ${output}"
}


usage() {
  echo -e "Usage:\n  sudo ./${SCRIPT_NAME} [-o output|-m model|-t target|-u]"
  echo '    -o specify output position, default is $PWD'
  echo '    -m specify model, rockpi4 or rockpis, default is rockpi4'
  echo '    -t specify target, backup or expand, default is backup'
  echo '    -u unattended backup image, no confirmations asked'
}


main() {
  echo -e "Welcome to use rockpi-backup.sh, part of the Rockpi toolkit.\n"
  echo -e "  Enter ${SCRIPT_NAME} -h to view help."
  echo -e "  For a description and example usage, see the README.md at:
    https://rock.sh/rockpi-toolbox \n"
  echo '--------------------'
  if [ "$target" == "expand" ]; then
    gdisk ${DEVICE} << EOF
w
y
y
EOF
    systemctl enable resize-helper
  else
    gen_partitions
    gen_image_file
    check_avail_space
    echo '--------------------'
    printf "The backup file will be saved at %s\n" "$output"
    printf "After this operation, %s MB of additional disk space will be used.\n" "$gpt_image_size"
    confirm "Do you want to continue?" "clean" "$output"
    backup_image
  fi
}


if [ "$print_help" == "1" ]; then
  usage
else
  main
fi
# end