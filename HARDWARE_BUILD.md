# Tracker unit — build, install and commissioning

The physical side of the six bus units: power, antennas, SIM, provisioning and
what to check before and after fitting.

## Which document is which

| Document | Answers |
|---|---|
| `HARDWARE.md` | What the unit must send. The contract. |
| `FIRMWARE.md` | How to write the code. MQTT packets, signing, counter. |
| **This one** | Everything that is not code: power, antennas, SIM, fitting. |

## The short answer

**You almost certainly do not need to build new hardware.** The units already in
the buses have the right parts. The work is firmware, plus a handful of physical
checks that are worth doing now because they are the usual reasons a unit that
worked on the bench fails in a bus.

| Item | Change needed |
|---|---|
| ESP32, GPS, SIM900A | None. Same parts, same wiring. |
| Firmware | **Yes** — see `FIRMWARE.md` |
| Per-unit secret in NVS | Yes if rotating, otherwise none |
| Power supply | Verify, and add bulk capacitance if it is not already there |
| Antennas | Verify placement |
| SIM card | Verify the carrier is not Jio |
| Enclosure, mounting | None |

The rest of this document is the detail behind that table.

## 1. Power — the most likely thing to bite

This is where 2G tracker projects usually fail, and the failure looks like a
firmware bug, so it is worth ruling out first.

### The SIM900A current problem

The SIM900A draws a short, violent burst of current every time it transmits:
roughly **2 A peaks lasting about 0.6 ms**, repeating at 217 Hz during a GPRS
burst. Its average draw is modest, so a supply sized on averages looks fine on
a bench and then browns out the moment the modem transmits from a moving bus
with a weak signal, where it transmits at full power.

Symptoms of an undersized supply, all of which look like software faults:

- The module registers on the network, then resets when it first transmits
- Random reboots that correlate with signal strength, not with code paths
- Works indoors near a window, fails in the middle of campus
- The ESP32 browns out and restarts while the modem is fine

What it needs:

- A supply that can deliver **2 A peak** at the module's input voltage, not
  just 2 A average
- **Bulk capacitance close to the module**: 1000 uF or more electrolytic,
  physically next to the SIM900A power pins, with a 100 nF ceramic beside it.
  This is what actually supplies the burst; the regulator only refills it.
- Short, thick power wiring to the module. Thin jumper wires have enough
  resistance to cause the brownout on their own.

If the units already run reliably on the bus today, this is already right and
you can leave it alone. **Check it if you see unexplained resets.**

### Bus power

Buses give you 12 V or 24 V nominal, electrically dirty, with load-dump spikes
when the engine stops or a large load disconnects. Expect:

- An automotive-rated buck converter, not a hobby module
- Reverse polarity protection
- Transient suppression on the input

### Ignition switching

Decide, and write down, which of these you have:

| Wiring | Behaviour | Trade-off |
|---|---|---|
| Ignition-switched | Unit powers down with the bus | No battery drain, no tracking when parked |
| Permanent (battery) | Always on | Tracks when parked, drains the battery overnight |

Ignition-switched is the safer default. The server handles a bus disappearing:
the Last Will marks it offline within about 90 seconds, and the timetable takes
over in the app.

If you go permanent, add a low-voltage cutoff so a flat bus battery is never
caused by the tracker.

### Clean shutdown

A supercapacitor or small LiPo lets the unit finish its current publish and
flush the counter to NVS when power is cut. Without it, the counter can lose
its last few increments — recoverable, because the firmware bumps it by 100 on
boot, but a clean shutdown is tidier.

## 2. Antennas — the second most likely thing to bite

Two antennas, and they interfere with each other.

### GPS antenna

- Needs **sky view**. A bus roof is metal; an antenna inside the cabin under a
  metal roof will get a poor fix or none.
- Best: on the roof, or inside against a window with a clear upward view.
- An active (amplified) patch antenna is worth it if the cable run is long.
- Cold start with no almanac can take **30 to 90 seconds** outdoors, and far
  longer with a poor view. Do not judge a unit by its first 30 seconds.

### GSM antenna

- Keep it **as far from the GPS antenna as the enclosure allows.** The 2G
  transmit burst is strong enough to desensitise a GPS receiver sitting next to
  it, which shows up as the fix dropping out exactly when the unit transmits.
- Do not coil excess coax tightly against the GPS module.
- A metal bus body blocks signal; the antenna should not be buried in the dash.

### Quick diagnosis

If a unit reports positions but they are wildly inaccurate or drop out
periodically, suspect antenna placement before suspecting the code. The server
logs rejections for out-of-area and implausible-jump fixes, which is a useful
signal that the GPS is struggling rather than the network.

## 3. SIM and network

| Requirement | Detail |
|---|---|
| Carrier | **Airtel, Vi or BSNL.** Not Jio. |
| Technology | 2G / GPRS must be available |
| Data | About 48 MB per bus per month at 5 s |
| Plan | 500 MB/month is comfortable |

**Jio has no 2G network at all** — it is VoLTE only. A Jio SIM in a SIM900A
will never register, no matter what the firmware does. This is worth checking
physically on each unit, because it is invisible in software until you read the
registration status.

Also confirm:

- The APN is set correctly for the carrier
- The SIM is activated and has data, not just voice
- SMS and voice are not needed and can be disabled on the plan
- 2G coverage exists on the campus routes. Check with a phone forced to 2G if
  you can, since coverage is being withdrawn in some areas.

Keep one spare activated SIM. A dead SIM is indistinguishable from a dead modem
until you swap it.

## 4. Per-unit provisioning

Each unit carries three values. They must match the server's `devices.json`.

| Value | Example | Where it lives |
|---|---|---|
| Device id | `esp32-01` | NVS, sent in the `d` field |
| Bus id | `bus1` | NVS, sent in `b`, also picks the topic |
| Secret | 32 hex characters | **NVS only.** Never in source. |

The six units map to buses as follows:

| Device | Bus |
|---|---|
| `esp32-01` | `bus1` |
| `esp32-02` | `bus2` |
| `esp32-03` | `bus3` |
| `esp32-04` | `bus4` |
| `esp32-05` | `ac_mbh` |
| `esp32-06` | `ac_lh` |

### Generating a secret

```bash
python3 -c "import secrets; print(secrets.token_hex(16))"
```

Put the same value in the unit's NVS and in the server's
`/etc/bustracker/devices.json`. Restart the server after editing it.

### Rotating the existing secrets

The six current secrets are in the repository's git history, so anyone with
repo access can forge that bus's position. Rotating means touching each unit,
which is why it has been deferred — but it is worth doing while the units are
open for the firmware update, because that visit is happening anyway.

### Label every unit

Physically label each enclosure with its device id. When a unit misbehaves you
need to know which one it is without opening it or reading the topic.

Keep a written record: device id, bus id, SIM number, date fitted, firmware
version. Six units is few enough that a sheet of paper works and a spreadsheet
is better.

## 5. Bench bring-up, before refitting

Do this on a desk with the unit powered from a proper supply, not from a laptop
USB port, which cannot supply the modem's burst current.

Leave this running on a laptop throughout:

```bash
mosquitto_sub -h broker.emqx.io -t 'cbt7f3c9e21b/bus/+/#' -v
```

1. Unit powers up and the modem registers on the network.
2. GPS gets a fix. Outdoors or by a window; allow 90 seconds.
3. Unit connects to the broker. `online` appears on its status topic.
4. A signed publish appears on the gps topic every 5 seconds.
5. Ask the server side to confirm the fix was **accepted**, not merely
   published. A message on the gps topic only proves it left the device.
6. Power the unit off. `offline` appears on the status topic within about 90
   seconds. This proves the Last Will is registered.
7. Power-cycle. It resumes with no manual step and the counter does not
   restart.
8. Disconnect the GSM antenna, then reconnect. It recovers without a reboot
   loop.
9. Run 30 minutes. Stable memory, one connection held, no reconnect storm.

Steps 5 and 6 are the ones people skip. Step 5 is the only proof the signature
is right; step 6 is the only proof the app will ever show the bus as offline.

## 6. Fitting to the bus

1. Mount the enclosure where it will not be kicked, soaked or cooked. Not on
   the engine bay side of a bulkhead.
2. Route the GPS antenna to its sky view. Secure the cable; a cable that works
   loose over a week of vibration is a common failure.
3. Keep the GSM antenna away from the GPS one.
4. Connect power. Confirm the polarity twice before energising.
5. Strain-relieve every cable. Buses vibrate constantly.
6. Power on and watch the laptop subscription until the bus appears.
7. Drive one full route and confirm the track looks sensible on the app, with
   no gaps and no jumps.

That last step is the real test. A unit can pass every bench check and still
lose signal in a particular dip on the route.

## 7. What can fail in service, and what to carry

| Symptom | First suspect | Check |
|---|---|---|
| Unit dead, no status topic | Power or fuse | Voltage at the unit |
| Resets when moving | Brownout on transmit | Bulk capacitance, wiring |
| Registers, never publishes | SIM data or APN | Registration status |
| Publishes, bus never appears | Signature or counter | Server log |
| Position wanders or drops | GPS antenna | Placement, cable |
| Fix lost only while transmitting | GSM desensing GPS | Antenna separation |
| Works, then stops after days | Counter, memory leak | Restart and watch |

Spares worth having, given it is a six-bus fleet:

- One complete spare unit, built and provisioned
- One spare activated SIM
- Spare GPS and GSM antennas, which are the parts that get damaged
- Fuses

A complete spare unit turns a roadside failure into a swap rather than a
diagnosis.

## 8. Things not to do

- Do not power the modem from the ESP32's onboard 3.3 V regulator. It cannot
  supply the burst.
- Do not use thin jumper wire for the modem's power.
- Do not mount the GPS antenna under a metal roof.
- Do not coil the GSM coax against the GPS module.
- Do not use a Jio SIM.
- Do not put the secret in source. NVS only.
- Do not fit a unit that has not passed steps 5 and 6 above.

## 9. Open questions

1. How are the units currently powered — ignition-switched or permanent?
2. Is there already bulk capacitance at the modem, and how thick is its power
   wiring?
3. Where are the two antennas physically, and how far apart?
4. Which carrier is in each unit?
5. Is the endpoint currently hard-coded or in NVS? This decides whether the
   firmware update is a reflash or a reconfiguration.
6. Is there a spare unit, or would a failure mean a bus goes dark?

Answers to 1 to 4 decide whether anything physical needs changing at all. My
expectation is that it does not, and the whole job is firmware.
