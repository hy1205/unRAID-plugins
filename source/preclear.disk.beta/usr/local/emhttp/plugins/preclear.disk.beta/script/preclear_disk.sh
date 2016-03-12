#!/bin/bash
LC_CTYPE=C
export LC_CTYPE

# Lets make sure some features are supported by BASH
BV=$(echo $BASH_VERSION|tr '.' "\n"|grep -Po "^\d+"|xargs printf "%.2d\n"|tr -d '\040\011\012\015')
if [ "$BV" -lt "040253" ]; then
  echo -e "Sorry, your BASH version isn't supported.\nThe minimum required version is 4.2.53.\nPlease update."
  exit 2
fi

# Let's verify all dependencies
for dep in cat awk basename blockdev comm date dd find fold getopt grep kill printf readlink seq sort strings sum tac tput udevadm xargs; do
  if ! type $dep >/dev/null 2>&1 ; then
    echo -e "The following dependency isn'y met: [$dep]\nPlease install it and try again."
    exit 1
  fi
done

######################################################
##                                                  ##
##                 PROGRAM FUNCTIONS                ##
##                                                  ##
######################################################

list_unraid_disks(){
  local _result=$1
  i=0
  # Get flash disk device
  unraid_disks[$i]=$(readlink -f /dev/disk/by-label/UNRAID|grep -Po "[^\d]*")

  # Grab cache disks using disks.cfg file
  if [ -f "/boot/config/disk.cfg" ]
  then
    while read line ; do
      if [ -n "$line" ]; then
        let "i+=1" 
        unraid_disks[$i]=$(find /dev/disk/by-id/ -type l -iname "*$line*" ! -iname "*-part*"| xargs readlink -f)
      fi
    done < <(cat /boot/config/disk.cfg|grep 'cacheId'|grep -Po '=\"\K[^\"]*')
  fi

  # Get array disks using super.dat id's
  if [ -f "/boot/config/super.dat" ]
  then
    while read line ; do
      disk=$(find /dev/disk/by-id/ -type l -iname "*${line}*" ! -iname "*-part*")
      if [ -n "$disk" ]
      then
        let "i+=1"
        unraid_disks[$i]=$(readlink -f $disk)
      fi
    done < <(strings /boot/config/super.dat|grep -x '.\{5,1000\}')
  fi
  eval "$_result=(${unraid_disks[@]})"
}

list_all_disks(){
  local _result=$1
  for disk in $(find /dev/disk/by-id/ -type l ! \( -iname "wwn-*" -o -iname "*-part*" \))
  do
    all_disks+=($(readlink -f $disk))
  done
  eval "$_result=(${all_disks[@]})"
}

is_preclear_candidate () {
  list_unraid_disks unraid_disks
  part=($(comm -12 <(for X in "${unraid_disks[@]}"; do echo "${X}"; done|sort)  <(echo $1)))
  if [ ${#part[@]} -eq 0 ] && [ $(cat /proc/mounts|grep -Poc "^${1}") -eq 0 ]
  then
    return 0
  else
    return 1
  fi
}

# list the disks that are not assigned to the array. They are the possible drives to pre-clear
list_device_names() {
  echo "====================================$ver"
  echo " Disks not assigned to the unRAID array "
  echo "  (potential candidates for clearing) "
  echo "========================================"
  list_unraid_disks unraid_disks
  list_all_disks all_disks
  unassigned=($(comm -23 <(for X in "${all_disks[@]}"; do echo "${X}"; done|sort)  <(for X in "${unraid_disks[@]}"; do echo "${X}"; done|sort)))

  if [ ${#unassigned[@]} -gt 0 ]
  then
    for disk in "${unassigned[@]}"
    do
      if [ $(cat /proc/mounts|grep -Poc "^${disk}") -eq 0 ]
      then
        serial=$(udevadm info --query=property --path $(udevadm info -q path -n $disk 2>/dev/null) 2>/dev/null|grep -Po "ID_SERIAL=\K.*")
        echo "     ${disk} = ${serial}"
      fi
    done
  else
    echo "No un-assigned disks detected."
  fi
}

# gfjardim - add notification system capability without breaking legacy mail.
send_mail() {
  subject=$(echo ${1} | tr "'" '`' )
  description=$(echo ${2} | tr "'" '`' )
  message=$(echo ${3} | tr "'" '`' )
  recipient=${4}
  if [ -f "$notify_script" ]; then
    $notify_script -e "Preclear ${model} ${serial}" -s """${subject}""" -d """${description}""" -m """${message}""" -i "normal ${notify_channels}"
  else
    echo -e "${message}" | mail -s "${subject}" "${recipient}"
  fi
}

append() {
  local _array=$1 _key;
  eval "local x=\${${1}+x}"
  if [ -z $x ]; then
    declare -g -A $1
  fi
  if [ "$#" -eq "3" ]; then
    el=$(printf "[$2]='%s'" "${@:3}")
  else
    for (( i = 0; i < 1000; i++ )); do
      eval "_key=\${$_array[$i]+x}"
      if [ -z "$_key" ] ; then
        break
      fi
    done
    el="[$i]=\"${@:2}\""
  fi
  eval "$_array+=($el)"; 
}

array_enumerate() {
  local i _column z
  for z in $@; do
    echo -e "array '$z'\n ("
    eval "_column="";for i in \"\${!$z[@]}\"; do  _column+=\"| | [\$i]| -> |\${$z[\$i]}\n\"; done"
    echo -e $_column|column -t -s "|"
    echo -e " )\n"
  done
}

array_content() { local _arr=$(eval "declare -p $1") && echo "${_arr#*=}"; }

read_mbr() {
  # called read_mbr [variable] "/dev/sdX" 
  local result=$1 disk=$2 i
  # verify MBR boot area is clear
  append mbr `dd bs=446 count=1 if=$disk 2>/dev/null        |sum|awk '{print $1}'`
  array_enumerate mbr
  # verify partitions 2,3, & 4 are cleared
  append mbr `dd bs=1 skip=462 count=48 if=$disk 2>/dev/null|sum|awk '{print $1}'`
  array_enumerate mbr
  # verify partition type byte is clear
  append mbr `dd bs=1 skip=450 count=1 if=$disk  2>/dev/null|sum|awk '{print $1}'`
  array_enumerate mbr

  # verify MBR signature bytes are set as expected
  append mbr `dd bs=1 count=1 skip=511 if=$disk 2>/dev/null |sum|awk '{print $1}'`
  array_enumerate mbr

  append mbr `dd bs=1 count=1 skip=510 if=$disk 2>/dev/null |sum|awk '{print $1}'`

  for i in $(seq 446 461); do
    append mbr `dd bs=1 count=1 skip=$i if=$disk 2>/dev/null|sum|awk '{print $1}'`
  done
  echo $(declare -p mbr)
}

verify_mbr() {
  # called verify_mbr "/dev/disX"
  local cleared
  local disk=$1
  local disk_blocks
  local i
  local max_mbr_blocks
  local mbr_blocks
  local over_mbr_size
  local partition_size
  local patterns
  declare sectors
  local start_sector 

  patterns=("00000" "00000" "00000" "00170" "00085")
  disk_blocks=$(blockdev --getsz $disk 2>/dev/null | awk '{ print $1 }')
  partition_size=$disk_blocks
  max_mbr_blocks=$(printf "%d" 0xFFFFFFFF)

  if [ $disk_blocks -ge $max_mbr_blocks ]; then
    over_mbr_size="y"
    patterns+=("00000" "00000" "00002" "00000" "00000" "00255" "00255" "00255")
  else
    patterns+=("00000" "00000" "00000" "00000" "00000" "00000" "00000" "00000")
  fi

  array=$(read_mbr sectors "$disk")
  eval "declare -A sectors="${array#*=}

  for i in $(seq 0 $((${#patterns[@]}-1)) ); do
    if [ "${sectors[$i]}" != "${patterns[$i]}" ]; then
      echo "Failed test 1: MBR signature is not valid. [${sectors[$i]}] != [${patterns[$i]}]"
      return 1
    fi
  done

  for i in $(seq ${#patterns[@]} $((${#sectors[@]}-1)) ); do
    if [ $i -le 16 ]; then
      start_sector="$(echo ${sectors[$i]}|awk '{printf("%02x", $1)}')${start_sector}"
    else
      mbr_blocks="$(echo ${sectors[$i]}|awk '{printf("%02x", $1)}')${mbr_blocks}"
    fi
  done

  start_sector=$(printf "%d" "0x${start_sector}")
  mbr_blocks=$(printf "%d" "0x${mbr_blocks}")

  case "$start_sector" in
    63) 
      let partition_size=($disk_blocks - $start_sector)
      ;;
    64)
      let partition_size=($disk_blocks - $start_sector)
      ;;
    1)
      if [ "$over_mbr_size" != "y" ]; then
        echo "Failed test 2: GPT start sector [$start_sector] is wrong, should be [1]."
        return 1
      fi
      ;;
    *)
      echo "Failed test 3: start sector is different from those accepted by unRAID."
      ;;
  esac
  if [ $partition_size -ne $mbr_blocks ]; then
    echo "Failed test 4: physical size didn't match MBR declared size. [$partition_size] != [$mbr_blocks]"
    return 1
  fi
  return 0
}


write_signature() {
  local disk=${disk_properties[device]}
  local disk_blocks=${disk_properties[blocks]} 
  local max_mbr_blocks partition_size size1=0 size2=0 sig start_sector=$1 var
  let partition_size=($disk_blocks - $start_sector)
  max_mbr_blocks=$(printf "%d" 0xFFFFFFFF)
  
  if [ $disk_blocks -ge $max_mbr_blocks ]; then
    size1=`printf "%d" "0x00020000"`
    size2=`printf "%d" "0xFFFFFF00"`
    start_sector=1
    partition_size=`printf "%d" 0xFFFFFFFF`
  fi

  dd if=/dev/zero bs=512 seek=1 of=$disk  count=4096 2>/dev/null
  dd if=/dev/zero bs=1 seek=462 count=48 of=$disk >/dev/null 2>&1
  dd if=/dev/zero bs=446 count=1 of=$disk  >/dev/null 2>&1
  echo -ne "\0252" | dd bs=1 count=1 seek=511 of=$disk >/dev/null 2>&1
  echo -ne "\0125" | dd bs=1 count=1 seek=510 of=$disk >/dev/null 2>&1

  for var in $size1 $size2 $start_sector $partition_size ; do
    for hex in $(tac <(fold -w2 <(printf "%08x\n" $var) )); do
      sig="${sig}\\x${hex}"
      # sig="${sig}$(printf '\\x%02x' "0x${hex}")"
    done
  done
  printf $sig| dd seek=446 bs=1 count=16 of=$disk >/dev/null 2>&1
}


write_zeroes(){
  # called write_zeroes
  local bytes_wrote=0
  local bytes_dd
  local cycle=$cycle
  local cycles=$cycles
  local current_speed
  local dd_pid
  local dd_output=${all_files[dd_out]}
  local disk=${disk_properties[device]}
  local disk_name=${disk_properties[name]}
  local percent_wrote
  local short_test=$short_test
  local stat_file=${all_files[stat]}
  local tb_formatted
  local total_bytes
  local write_bs=""
  local time_start

  time_start=$(timer)

  if [ "$short_test" == "y" ]; then
    total_bytes=8589934592   # 2048k * 4096
  else
    total_bytes=${disk_properties[size]}
  fi
  tb_formatted=$(format_number $total_bytes)
  
  if [ "$write_bs" = "" ]; then
    write_bs="2048k"
  fi

  if [ "$short_test" == "y" ]; then
    dd if=/dev/zero bs=2048k seek=1 of=$disk count=4096 2> $dd_output &
  else
    dd if=/dev/zero bs=$write_bs seek=1 of=$disk        2> $dd_output &
  fi
  dd_pid=$!

  # if we are interrupted, kill the background zero of the disk.
  trap 'kill -9 $dd_pid 2>/dev/null;exit' 2
  while kill -0 $dd_pid >/dev/null 2>&1; do
    sleep 3 && kill -USR1 $dd_pid && sleep 2
    # ensure bytes_wrote is a number
    bytes_dd=$(awk 'END{print $1}' $dd_output|xargs)
    if [ ! -z "${bytes_dd##*[!0-9]*}" ]; then
      bytes_wrote=$bytes_dd
    fi
    let percent_wrote=($bytes_wrote*100/$total_bytes)
    if [ ! -z "${bytes_wrote##*[!0-9]*}" ]; then
      let percent_wrote=($bytes_wrote*100/$total_bytes)
    fi
    current_speed=$(awk 'END{print $8$9}' $dd_output)
    time_current=$(timer)

    status="Time elapsed: $(timer $time_start) | Write speed: $current_speed | Average speed: $(($bytes_wrote / ($time_current - $time_start) / 1048576 ))MB/s"
    if [ "$cycles" -gt 1 ]; then
      cycle_disp="($cycle of $cycles)"
    fi

    echo "$disk_name|NN|Zeroing${cycle_disp}: ${percent_wrote}% @ $current_speed MB/s ($(timer $time_start))|$$" >$stat_file
    
    if [ -z "${time_display}" ]; then
      time_display=$(timer)
    else
      if [ "$(( $time_current - $time_display ))" -gt "$refresh_period" ]; then
        time_display=$(timer)
        display_status "Zeroing in progress: # ${ul}(${percent_wrote}% Done)${noul}" "** $status"
      fi
    fi
  done
}

format_number() {
  echo " $1 " | sed -r ':L;s=\b([0-9]+)([0-9]{3})\b=\1,\2=g;t L'|xargs
}

# Keep track of the elapsed time of the preread/clear/postread process
timer() {
  if [[ $# -eq 0 ]]; then
    echo $(date '+%s')
  else
    local  stime=$1
    etime=$(date '+%s')

    if [[ -z "$stime" ]]; 
      then stime=$etime; 
    fi

    dt=$((etime - stime))
    ds=$((dt % 60))
    dm=$(((dt / 60) % 60))
    dh=$((dt / 3600))
    printf '%d:%02d:%02d' $dh $dm $ds
  fi
}

is_numeric() {
  local _var=$2 _num=$3
  if [ ! -z "${_num##*[!0-9]*}" ]; then
    eval "$1=$_num"
  else
    echo "$_var value [$_num] is not a number. Please verify your commad arguments.";
    exit 2
  fi
}

read_entire_disk() { 
  local actual_bytes
  local bcount
  local bytes_read
  local chunk
  local dd_cmd
  local next_chunk_read
  local percent_read
  local post_read_err read_chunk   read_limit read_speed  rsum      skip_b1         skip_b2 
  local skip_b3       skip_p1      skip_p2    skip_p3     skip_p4   skip_p5         time_start
  local time_current  time_display read_type  read_type_s total_bytes
  local cycle=$cycle
  local cycles=$cycles
  local dd_output=${all_files[dd_out]}
  local disk=${disk_properties[device]}
  local disk_name=${disk_properties[name]}
  local short_test=$short_test
  local read_size=$read_size
  local skip=0
  local verify=$1
  local read_type=$2
  local stat_file=${all_files[stat]}
  local verify_errors=${all_files[verify_errors]}

  # Type of read: Pre-Read or Post-Read
  if [ "$read_type" == "preread" ]; then
    read_type="Pre-read in progress:"
    read_type_s="Pre-Read"
  elif [ "$read_type" == "postread" ]; then
    read_type="Post-Read in progress:"
    read_type_s="Post-Read"
  else
    read_type="Verifying if disk is zeroed:"
    read_type_s="Verify Zeroing"
    read_stress=n
  fi

  # start time
  time_start=$(timer)

  # Read memory limit in bytes
  if [ -n "$read_size" ]; then
    read_limit=$read_size
  else
    read_limit=134217728  # 128 MB
    read_limit=402653184  # 384 MB
    read_limit=671088640  # 640 MB
    read_limit=1073741824 # 1GB
    read_limit=268435456  # 256 MB
  fi

  if [ "$short_test" == "y" ]; then
    actual_bytes=${disk_properties[size]}
    total_bytes=1074511872 #Debug case..  Set total size to ~1GB disk to speed up test
    if [ "$actual_bytes" -lt "$total_bytes" ]; then
      let total_bytes=( $actual_bytes / 10 )
    fi
  else
    total_bytes=${disk_properties[size]}
  fi
  tb_formatted=$(format_number $total_bytes)

  # Record chunk that will be read every loop
  # BYTES        CHUNK
  # 103219200 -> 516096
  # 154828800 -> 774144 
  # 309657600 -> 1548288
  chunk=516096

  # Number of chunks to be read every loop
  bcount=200
  for i in $(seq 100 100000); do
    if [ "$(( $chunk * $i ))" -le "$read_limit" ]; then
      bcount=$i
    fi
  done

  let total_chunks=($total_bytes / $chunk)
  
  # echo total_bytes=[$total_bytes] bcount=[$bcount]
  # echo chunk=[$chunk] total_chunks=[$total_chunks]
  # echo bytes per read $(( $chunk * $bcount ))
  #dd if=$disk bs=$chunk count=$bcount skip=$skip conv=noerror
  while [ "$skip" -le "$total_chunks" ]; do

    # Break loop if it's the end of the disk
    if [ "$skip" -eq "$total_chunks" ]; then
      # echo end_of_disk
      break
    fi

    # Stress the disk if requested
    if [ "$read_stress" == "y" ]; then
      # read a random block.
      skip_b1=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($total_chunks) ))
      dd if=$disk of=/dev/null count=1 bs=$chunk skip=$skip_b1 >/dev/null 2>&1 &
      skip_p1=$!

      # read the first block here, bypassing the buffer cache by use of iflag=direct
      dd if=$disk of=/dev/null count=1 bs=$chunk iflag=direct >/dev/null 2>&1 &
      skip_p2=$!

      # read a random block.
      skip_b2=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($total_chunks) ))
      dd if=$disk of=/dev/null count=1 bs=$chunk skip=$skip_b2 >/dev/null 2>&1 &
      skip_p3=$!

      # read the last block here, bypassing the buffer cache by use of iflag=direct
      dd if=$disk of=/dev/null count=1 bs=$chunk skip=$last_block iflag=direct >/dev/null 2>&1 &
      skip_p4=$!

      # read a random block.
      skip_b3=$(( 0+(`head -c4 /dev/urandom| od -An -tu4`)%($total_chunks) ))
      dd if=$disk of=/dev/null count=1 bs=$chunk skip=$skip_b3 >/dev/null 2>&1 &
      skip_p5=$!

      # make sure the background random blocks are read before continuing
      kill -0 $skip_p1 2>/dev/null && wait $skip_p1
      kill -0 $skip_p2 2>/dev/null && wait $skip_p2
      kill -0 $skip_p3 2>/dev/null && wait $skip_p3
      kill -0 $skip_p4 2>/dev/null && wait $skip_p4
      kill -0 $skip_p5 2>/dev/null && wait $skip_p5
    fi
    
    # do the read
    if [ "$verify" == "verify" ]; then
      # first block must be treated differently
      if [ "$skip" -eq "0" ]; then
        dd_cmd="dd if=$disk bs=512 count=8192 skip=1 conv=noerror"
      else 
        dd_cmd="dd if=$disk bs=$chunk count=$bcount skip=$skip conv=noerror"
      fi
      rsum=$($dd_cmd 2>$dd_output|sum|awk '{print $1}')
      if [ "$rsum" != "00000" ]; then
        echo " > Command '$dd_cmd' returned $rsum instead of 00000" >$verify_errors
        return 1
      fi
    else
      dd if=$disk of=/dev/null bs=$chunk count=$bcount skip=$skip conv=noerror >$dd_output 2>&1
    fi

    # update the skip count
    let skip=($skip + $bcount)

    # calculate the current status
    let bytes_read=($skip * $chunk)
    let percent_read=( $bytes_read*100/$total_bytes)
    read_speed=$(awk 'END{print $8$9}' $dd_output)
    time_current=$(timer)

    status="Time elapsed: $(timer $time_start) | Current speed: $read_speed | Average speed: $(($bytes_read / ($time_current - $time_start) / 1048576 ))MB/s"
    if [ "$cycles" -gt 1 ]; then
      cycle_disp="($cycle of $cycles)"
    fi
    echo "$disk_name|NN|${read_type_s}${cycle_disp}: ${percent_read}% @ $read_speed MB/s ($(timer $time_start))|$$" > $stat_file

    if [ -z "${time_display}" ]; then
      time_display=$(( $(timer) - $refresh_period ))
    else
      if [ "$(( $time_current - $time_display ))" -gt "$refresh_period" ]; then
        time_display=$(timer)
        display_status "$read_type # ${ul}(${percent_read}% Done)${noul}" "** $status"
      fi
    fi

    # if the next chunk to be read exceedes the total_chunks value, decrease the bcount value
    let next_chunk_read=($skip + $bcount )
    if [ $next_chunk_read -gt $total_chunks ]; then
      let bcount=($total_chunks - $skip)
    fi
  done
}

draw_canvas(){
  local height=$1 width=$2 brick=$canvas_brick

  eval "local x=\${canvas+x}"
  if [ -z $x ]; then
    declare -g canvas;
    for line in $(seq 0 $height); do
      canvas+=$(tput cup $line 0 && echo $brick)
      canvas+=$(tput cup $line $width && echo $brick)
    done
    for col in $(seq $width); do
      canvas+=$(tput cup 0 $col && echo $brick)
      canvas+=$(tput cup $height $col && echo $brick)
      canvas+=$(tput cup $(( $height - 2 )) $col && echo $brick)
    done
  fi
  echo -e "$canvas\n"
}

display_status(){
  local max=$max_steps
  local cycle=$cycle
  local cycles=$cycles
  local current=$1
  local status=$2
  local stat=""
  local width=$canvas_width
  local height=$canvas_height
  local brick=$canvas_brick
  local all_timer=$all_timer
  local cycle_timer=$cycle_timer
  local inipos=4
  local do_reset=$3
  local step=1

  eval "local -A prev=$(array_content display_step)"
  eval "local -A title=$(array_content display_title)"

  if [ "$do_reset" != "n" ]; then
    tput reset
  fi

  draw_canvas $height $width 

  for (( i = 0; i <= ${#title[@]}; i++ )); do
    line=${title[$i]}
    line_num=$(echo "$line"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
    tput cup $(($i+2)) $(( $width/2 - $line_num/2  )); echo "$line"
  done

  l=$((${#title[@]}+5))

  for i in "${!prev[@]}"; do
    if [ -n "${prev[$i]}" ]; then
      line=${prev[$i]}
      stat=""
      if [ "$(echo "$line"|grep -c '#')" -gt "0" ]; then
        stat=$(echo "$line"|cut -d'#' -f2)
        line=$(echo "$line"|cut -d'#' -f1)
      fi
      if [ -n "$max" ]; then
        line="Step $step of $max - $line"
      fi
      tput cup $l $inipos && echo $line
      if [ -n "$stat" ]; then
        stat_num=$(echo "$stat"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
        tput cup $l $(($width - $stat_num - 1 )) && echo "$stat"
      fi
      let "l+=1"
      let "step+=1"
    fi
  done
  if [ -n "$current" ]; then
    line=$current;
    stat=""
    if [ "$(echo "$line"|grep -c '#')" -gt "0" ]; then
      stat=$(echo "$line"|cut -d'#' -f2)
      line=$(echo "$line"|cut -d'#' -f1)
    fi
    if [ -n "$max" ]; then
      line="Step $step of $max - $line"
    fi
    tput cup $l $inipos && echo $line
    if [ -n "$stat" ]; then
      stat_num=$(echo "$stat"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
      tput cup $l $(($width - $stat_num - 1 )) && echo "$stat"
    fi
    let "l+=1"
  fi
  if [ -n "$status" ]; then
    tput cup $(($height-4)) $inipos && echo -e "$status"
  fi

  footer="Total elapsed time: $(timer $all_timer)"
  if [[ -n "$cycle_timer" ]]; then
    footer="Cycle elapsed time: $(timer $cycle_timer) | $footer"
  fi
  footer_num=$(echo "$footer"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
  tput cup $(( $height - 1)) $(( $width/2 - $footer_num/2  )); echo "$footer"

  tput cup $(( $height + 2 )) 0

}

ask_preclear(){
  local line
  local inipos=4
  local max=""
  local width=$canvas_width
  local height=$canvas_height
  eval "local -A title=$(array_content display_title)"
  eval "local -A disk_info=$(array_content disk_properties)"

  tput reset

  draw_canvas

  for (( i = 0; i <= ${#title[@]}; i++ )); do
    line=${title[$i]}
    line_num=$(echo "$line"|tr -d "${bold}"|tr -d "${norm}"|tr -d "${ul}"|tr -d "${noul}"|wc -m)
    tput cup $(($i+2)) $(( $width/2 - $line_num/2  )); echo "$line"
  done

  l=$((${#title[@]}+5))

  if [ -n "${disk_info[family]}" ]; then
    tput cup $l $inipos && echo "Model Family:   ${disk_info[family]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[model]}" ]; then
    tput cup $l $inipos && echo "Device Model:   ${disk_info[model]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[serial]}" ]; then
    tput cup $l $inipos && echo "Serial Number:  ${disk_info[serial]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[size_human]}" ]; then
    tput cup $l $inipos && echo "User Capacity:  ${disk_info[size_human]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[firmware]}" ]; then
    tput cup $l $inipos && echo "Firmware:       ${disk_info[firmware]}"
    let "l+=1"
  fi
  if [ -n "${disk_info[device]}" ]; then
    tput cup $l $inipos && echo "Disk Device:    ${disk_info[device]}"
  fi

  tput cup $(($l+4)) $inipos && echo "Type ${bold}Yes${norm} to proceed: "
  tput cup $(($l+4)) $(($inipos+21)) && read answer

  tput cup $(( $height - 1)) $inipos; 

  if [[ "$answer" == "Yes" ]]; then
    tput cup $(( $height + 2 )) 0
    return 0
  else
    echo "Wrong answer. The disk will ${bold}NOT${norm} be precleared."
    tput cup $(( $height + 2 )) 0
    exit 2
  fi
}


######################################################
##                                                  ##
##                  PARSE OPTIONS                   ##
##                                                  ##
######################################################

#Defaut values
read_stress=y
cycles=1
append display_step ""
verify_mbr_only=n
refresh_period=10
canvas_width=90
canvas_height=20
canvas_brick=#
version="Beta 0.1"

OPTS=$(getopt -o f:n:sSr:w:b:tdlc:ujv \
      --long frequency:,notify:,skip-preread,skip-postread,read-size:,write-size:,read-blocks:,test,no-stress,list,cycles:,signature,verify,no-prompt -n "$(basename $0)" -- "$@")

if [ "$?" -ne "0" ]; then
  exit 1
fi

eval set -- "$OPTS"
# (set -o >/dev/null; set >/tmp/.init)
while true ; do
  case "$1" in
    -f|--frequency)     is_numeric notify_freq    "$1" "$2"; shift 2;;
    -n|--notify)        is_numeric notify_channel "$1" "$2"; shift 2;;
    -s|--skip-preread)  skip_preread=y;                      shift 1;;
    -S|--skip-postread) skip_postread=y;                     shift 1;;
    -r|--read-size)     is_numeric read_size      "$1" "$2"; shift 2;;
    -w|--write-size)    is_numeric write_size     "$1" "$2"; shift 2;;
    -b|--read-blocks)   is_numeric read_blocks    "$1" "$2"; shift 2;;
    -t|--test)          short_test=y;                        shift 1;;
    -d|--no-stress)     read_stress=n;                       shift 1;;
    -l|--list)          list_device_names;                   exit 0 ;;
    -c|--cycles)        is_numeric cycles         "$1" "$2"; shift 2;;
    -u|--signature)     verify_disk_mbr=y;                   shift 1;;
    -p|--verify)        verify_disk_mbr=y; verify_zeroed=y;  shift 1;;
    -j|--no-prompt)     no_prompt=y;                         shift 1;;
    -v|--version)       echo "$0 version: $version"; exit 0; shift 1;;

    --) shift ; break ;;
    * ) echo "Internal error!" ; exit 1 ;;
  esac
done

if [ ! -b "$1" ]; then
  echo "Disk not set, please verify the command arguments."
  exit 1
fi
theDisk=$(echo $1|xargs)
# diff /tmp/.init <(set -o >/dev/null; set)
# exit 0
######################################################
##                                                  ##
##          SET DEFAULT PROGRAM VARIABLES           ##
##                                                  ##
######################################################

# Disk properties
append disk_properties 'device'   "$theDisk"
append disk_properties 'size'     $(blockdev --getsize64 ${disk_properties[device]} 2>/dev/null)
append disk_properties 'block_sz' $(blockdev --getpbsz ${disk_properties[device]} 2>/dev/null)
append disk_properties 'blocks'   $(( ${disk_properties[size]} / ${disk_properties[block_sz]} ))
append disk_properties 'name'     $(basename ${disk_properties[device]} 2>/dev/null)
append disk_properties 'parts'    $(grep -c "${disk_properties[name]}[0-9]" /proc/partitions 2>/dev/null)

if [ "${disk_properties[parts]}" -gt 0 ]; then
  for part in $(seq 1 "${disk_properties[parts]}" ); do
    let "parts+=($(blockdev --getsize64 ${disk_properties[device]}${part} 2>/dev/null) / ${disk_properties[block_sz]})"
  done
  append disk_properties 'start_sector' $(( ${disk_properties[blocks]} - $parts ))
else
  append disk_properties 'start_sector' "0"
fi

# Disable read_stress if preclearing a SSD
discard=$(cat "/sys/block/${disk_properties[name]}/queue/discard_max_bytes")
if [ "$discard" -gt "0" ]; then
  read_stress=n
fi

# Parse SMART info
while read line ; do
  if [[ $line =~ Model\ Family:\ (.*) ]]; then
    append disk_properties 'family' "$(echo "${BASH_REMATCH[1]}"|xargs)"
  elif [[ $line =~ Device\ Model:\ (.*) ]]; then
    append disk_properties 'model' "$(echo "${BASH_REMATCH[1]}"|xargs)"
  elif [[ $line =~ Serial\ Number:\ (.*) ]]; then
    append disk_properties 'serial' "$(echo "${BASH_REMATCH[1]}"|xargs)"
  elif [[ $line =~ User\ Capacity:\ (.*) ]]; then
    append disk_properties 'size_human' "$(echo "${BASH_REMATCH[1]}"|xargs)"
  elif [[ $line =~ Firmware\ Version:\ (.*) ]]; then
    append disk_properties 'firmware' "$(echo "${BASH_REMATCH[1]}"|xargs)"
  fi
done < <(smartctl --info -d sat,auto "$theDisk")

# Used files
append all_files 'dir'           "/tmp/.preclear/${disk_properties[name]}"
append all_files 'dd_out'        "${all_files[dir]}/dd_output"
append all_files 'verify_errors' "${all_files[dir]}/verify_errors"
append all_files 'stat'         " /tmp/preclear_stat_${disk_properties[name]}"
mkdir -p "${all_files[dir]}"

# Set terminal variables
if [ -x /usr/bin/tput ]; then
  clearscreen=`tput clear`
  goto_top=`tput cup 0 1`
  screen_line_three=`tput cup 3 1`
  bold=`tput smso`
  norm=`tput rmso`
  ul=`tput smul`
  noul=`tput rmul`
else
  clearscreen=`echo -n -e "\033[H\033[2J"`
  goto_top=`echo -n -e "\033[1;2H"`
  screen_line_three=`echo -n -e "\033[4;2H"`
  bold=`echo -n -e "\033[7m"`
  norm=`echo -n -e "\033[27m"`
  ul=`echo -n -e "\033[4m"`
  noul=`echo -n -e "\033[24m"`
fi

# set init timer
all_timer=$(timer)

# set the default canvas
draw_canvas $canvas_height $canvas_width >/dev/null

######################################################
##                                                  ##
##                MAIN PROGRAM BLOCK                ##
##                                                  ##
######################################################

if ! is_preclear_candidate $theDisk; then
  echo -e "\n${bold}The disk '$theDisk' is part of unRAID's array, or is assigned as a cache device.${norm}"
  echo -e "\nPlease choose another one from below:\n"
  list_device_names
  echo -e "\n"
  exit 1
fi

######################################################
##              VERIFY PRECLEAR STATUS              ##
######################################################

if [ "$verify_disk_mbr" == "y" ]; then
  max_steps=1
  if [ "$verify_zeroed" == "y" ]; then
    max_steps=2
  fi
  append display_title "${ul}unRAID Server: verifying Preclear State of '$theDisk${noul}' ."
  append display_title "Verifying disk '$theDisk' for unRAID's Preclear State."

  display_status "Verifying unRAID's signature on the MBR ..." ""
  echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR...|$$" > ${all_files[stat]}
  sleep 10
  if verify_mbr $theDisk; then
    append display_step "Verifying unRAID's Preclear MBR: # ${bold}SUCCESS${norm}"
    echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR successful|$$" > ${all_files[stat]}
    display_status
  else
    append display_step "Verifying unRAID's signature: # ${bold}FAIL${norm}"
    echo "${disk_properties[name]}|NY|Verifying unRAID's signature on the MBR failed|$$" > ${all_files[stat]}
    display_status
    echo Failed
    exit 1
  fi
  if [ "$max_steps" -eq "2" ]; then
    display_status "Verifying if disk is zeroed ..." ""
    if read_entire_disk verify 'zeroed' ; then
      append display_step "Verifying if disk is zeroed:#${bold}SUCCESS${norm}"
      echo "${disk_properties[name]}|NN|Verifying if disk is zeroed: SUCCESS|$$" > ${all_files[stat]}
      display_status
      sleep 10
    else
      append display_step "Verifying if disk is zeroed:#${bold}FAIL${norm}"
      echo "${disk_properties[name]}|NY|Verifying if disk is zeroed successful|$$" > ${all_files[stat]}
      exit 1
      display_status
    fi
  fi
  echo "${disk_properties[name]}|NN|The disk is Precleared!|$$" > ${all_files[stat]}
  exit 0
fi

######################################################
##                 PRECLEAR THE DISK                ##
######################################################

append display_title "${ul}unRAID Server Pre-Clear of disk${noul} ${bold}$theDisk${norm}"

if [ "$no_prompt" != "y" ]; then
  ask_preclear
fi

# reset timer
all_timer=$(timer)

for cycle in $(seq $cycles); do
  # Set a cycle timer
  cycle_timer=$(timer)

  # Reset canvas title
  unset display_title
  unset display_step
  append display_title "${ul}unRAID Server Pre-Clear of disk${noul} ${bold}$theDisk${norm}"
  append display_title "Cycle ${bold}${cycle}$norm of ${cycles}, partition start on sector 64."
  
  # Adjust the number of steps
  max_steps=5
  if [ "$skip_preread" == "y" ]; then
    let max_steps-=1
  fi
  if [ "$skip_postread" == "y" ]; then
    let max_steps-=1
  fi

  # Do a preread if not skipped
  if [ "$skip_preread" != "y" ]; then
    display_status "Pre-Read in progress ..." ""
    if read_entire_disk no-verify 'preread'; then
      append display_step "Pre-read verification:#${bold}SUCCESS${norm}"
      display_status
    else
      append display_step "Pre-read verification ${bold}FAIL${norm}"
      display_status
      echo "${disk_properties[name]}|NY|Pre-read verification failed - Aborted|$$" > ${all_files[stat]}
      echo "--> FAIL: Result: Pre-Read failed."
      exit 1
    fi
  fi

  # Zero the disk
  display_status "Zeroing in progress ..." ""
  write_zeroes
  sleep 10
  append display_step "Zeroing the disk: # ${bold}SUCCESS${norm}"
  sleep 10

  # Write unRAID's preclear signature to the disk
  display_status "Writing unRAID's Preclear signature to the disk ..." ""
  echo "${disk_properties[name]}|NN|Writing unRAID's Preclear signature|$$" > ${all_files[stat]}
  write_signature 64
  sleep 10
  append display_step "Writing unRAID's Preclear signature: # ${bold}SUCCESS${norm}"
  echo "${disk_properties[name]}|NN|Writing unRAID's Preclear signature finished|$$" > ${all_files[stat]}
  sleep 10

  # Verify unRAID's preclear signature in disk
  display_status "Verifying unRAID's signature on the MBR ..." ""
  echo "${disk_properties[name]}|NN|Verifying unRAID's signature on the MBR|$$" > ${all_files[stat]}
  if verify_mbr $theDisk; then
    append display_step "Verifying unRAID's Preclear signature: # ${bold}SUCCESS${norm}"
    display_status
    echo "${disk_properties[name]}|NN|unRAID's signature on the MBR successful|$$" > ${all_files[stat]}
  else
    append display_step "Verifying unRAID's Preclear signature: # ${bold}FAIL${norm}"
    display_status
    echo "--> FAIL: unRAID's Preclear signature not valid. "
    echo "${disk_properties[name]}|NY|unRAID's signature on the MBR failed - Aborted|$$" > ${all_files[stat]}
    exit 1
  fi

  # Do a post-read if not skipped
  if [ "$skip_postread" != "y" ]; then
    display_status "Post-Read in progress ..." ""
    if read_entire_disk verify 'postread' ; then
      append display_step "Post-Read verification:#${bold}SUCCESS${norm}"
      display_status
      echo "${disk_properties[name]}|NY|Post-Read verification successful|$$" > ${all_files[stat]}

    else
      append display_step "Post-Read verification ${bold}FAIL${norm}"
      display_status
      echo "--> FAIL: Post-Read verification failed. Your drive is not zeroed."
      echo "${disk_properties[name]}|NY|Post-Read verification failed - Aborted|$$" > ${all_files[stat]}
      # cat "${all_files[verify_errors]}"
      exit 1
    fi
  fi
done
echo "${disk_properties[name]}|NN|Preclear Finished Successfully!|$$" > ${all_files[stat]}

