# VMware VM Hardware Access Limitations

When running on VMware (ESXi/vSphere), guest OS cannot access host hardware sensors.

## Thermal Sensors

**Host CPU/GPU temperatures are NOT available in guest VMs** by default:

| Method | Result in VM | Explanation |
|--------|-------------|-------------|
| `/sys/class/thermal/` | ❌ No thermal zones | VMware doesn't expose thermal sysfs |
| `sensors` (lm-sensors) | ❌ No hwmon sensors | No hwmon devices forwarded |
| `/proc/acpi/thermal_zone` | ❌ Not found | ACPI thermal zones are host-only |
| `ipmitool sensor list` | ❌ Not available | BMC is on host, not in VM |

### How to detect you're on a VMware VM

```bash
# Check hypervisor
lscpu | grep Hypervisor
# Output: "Hypervisor vendor:                       VMware"

# Check for hwmon
cat /sys/class/hwmon/hwmon0/name
# May show "ACAD" (battery sensor, irrelevant for desktop/VM)
```

### Workarounds

1. **View from vCenter/ESXi** — Check host monitoring dashboard for CPU temps
2. **Enable host-to-guest telemetry** — VMware Tools may provide limited telemetry, but thermal data is not part of standard guest-to-host passthrough
3. **Use host-side tools** — Run `sensors` or `ipmitool` on the ESXi host (via SSH on ESXi) or a management VM that has bare-metal access

### Not VMware?

Same issue applies to **VirtualBox**, **VMware Workstation**, and most other hypervisors — guest OS hardware sensor access is typically not forwarded. This is **not a bug**, it's by design for security and isolation.
