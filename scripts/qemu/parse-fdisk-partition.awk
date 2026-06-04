# Extract the start sector of partition 2 from fdisk -l output.
# Designed to be called as:
#   fdisk -l IMAGE | awk -f parse-fdisk-partition.awk
#
# Tolerates both util-linux fdisk output formats:
#   Old (pre-2.38): Boot StartCHS EndCHS StartLBA EndLBA Sectors Size Id Type
#   New (>=2.38):   Boot StartLBA EndLBA Sectors Size Id Type
#
# The match condition $1 ~ /(^|[^[:digit:]])2$/ requires the device
# column to END with a non-digit followed by `2`, which excludes
# higher-numbered partitions like /dev/loop0p12 (where the character
# before `2` is the digit `1`).
#
# After matching, we scan columns 2..NF and print the first field
# that is purely numeric — that field is StartLBA in both formats
# (in the old format, the prior field is StartCHS which contains a
# comma and is therefore not purely numeric).
#
# Callers should pipe the output through `tail -1` to disambiguate
# when an image lists both /dev/loopXp2 and images/file.img2 rows
# (fdisk -l shows loop rows before file rows; the script's
# `tail -1` picks the file row by design).
{
    if ($1 ~ /(^|[^[:digit:]])2$/) {
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/) {
                print $i
                next
            }
        }
    }
}
