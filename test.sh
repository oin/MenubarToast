#!/bin/bash
cd "$(dirname "$0")"
make -s || exit 1

messages=(
    # Simple short
    "Build OK"
    "Salut"
    "Done"
    "42"

    # Bold
    "**Build succeeded** — 0 warnings"
    "**Erreur** critique détectée"
    "Nouveau commit par **Alice**"

    # Colors
    "{color:green}All tests passed{/color}"
    "{color:red}3 failures{/color} in test suite"
    "{color:orange}Warning:{/color} disk usage at 89%"
    "{color:cyan}Info:{/color} deployment started"
    "{color:#FF6B9D}Custom pink{/color} message"

    # Icons
    "{icon:checkmark.circle.fill} Deployed"
    "{icon:xmark.octagon.fill} Build failed"
    "{icon:bell.fill} New notification"
    "{icon:wifi} Connected"
    "{icon:battery.75percent} Battery OK"
    "{icon:cup.and.saucer.fill} Coffee ready"

    # Colored icons — various SF Symbols categories
    "{color:green}{icon:checkmark.circle.fill}{/color} Deployed successfully"
    "{color:red}{icon:xmark.circle.fill}{/color} Build failed"
    "{color:orange}{icon:exclamationmark.triangle.fill}{/color} Warning"
    "{color:blue}{icon:arrow.down.circle.fill}{/color} Download complete"
    "{color:purple}{icon:wand.and.stars}{/color} Magic happened"
    "{color:red}{icon:heart.fill}{/color} Liked by **Emma**"
    "{color:green}{icon:leaf.fill}{/color} Eco mode enabled"
    "{color:cyan}{icon:snowflake}{/color} Temperature: **-3°C**"
    "{color:#FF9500}{icon:flame.fill}{/color} Trending now"
    "{color:blue}{icon:cloud.rain.fill}{/color} Rain expected at 3pm"
    "{color:green}{icon:bolt.fill}{/color} Fast charge active"
    "{color:red}{icon:lock.fill}{/color} Session locked"
    "{color:blue}{icon:link}{/color} Link copied"
    "{color:orange}{icon:star.fill}{/color} New rating: **4.8/5**"
    "{color:purple}{icon:sparkles}{/color} AI analysis complete"
    "{color:green}{icon:arrow.triangle.2.circlepath}{/color} Sync complete"
    "{color:red}{icon:trash.fill}{/color} 12 items deleted"
    "{color:cyan}{icon:paperplane.fill}{/color} Message sent"
    "{color:orange}{icon:clock.fill}{/color} Reminder in **5 min**"
    "{color:blue}{icon:map.fill}{/color} Location shared"

    # Icons + colors + bold — full combos
    "{color:green}{icon:checkmark.circle.fill}{/color} {color:green}**All 128 tests passed**{/color}"
    "{color:red}{icon:xmark.octagon.fill}{/color} {color:red}**FATAL:**{/color} segfault in main.c"
    "{color:blue}{icon:arrow.up.circle.fill}{/color} {color:blue}**v2.4.1**{/color} pushed to production"
    "{color:orange}{icon:bell.badge.fill}{/color} {color:orange}**3 unread**{/color} messages"
    "{color:yellow}{icon:externaldrive.fill}{/color} {color:yellow}**Warning:**{/color} backup incomplete"
    "{color:red}{icon:heart.fill}{/color} **Sarah** {color:red}loved{/color} your photo"
    "{color:green}{icon:dollarsign.circle.fill}{/color} Payment of {color:green}**€42.00**{/color} received"
    "{color:purple}{icon:cpu.fill}{/color} {color:purple}**GPU**{/color} rendering complete — 847 frames"
    "{color:cyan}{icon:antenna.radiowaves.left.and.right}{/color} {color:cyan}**5G**{/color} connected — 847 Mbps"
    "{color:orange}{icon:shippingbox.fill}{/color} Package {color:orange}**#8847**{/color} out for delivery"

    # Realistic notifications with colored icons
    "{color:blue}{icon:envelope.fill}{/color} Mail from **John** — Hey, are you free for lunch?"
    "{color:purple}{icon:bubble.left.fill}{/color} **Slack** — #general: deploy is live"
    "{color:red}{icon:calendar}{/color} Meeting in **15 min** — Sprint Review"
    "{color:gray}{icon:gear}{/color} System update available: **macOS 15.3**"
    "{color:green}{icon:phone.fill}{/color} Call ended — **12:34**"
    "{color:orange}{icon:person.fill.badge.plus}{/color} **Alex** started following you"
    "{color:blue}{icon:music.note}{/color} Now playing: **Daft Punk** — Around the World"

    # Long — triggers scroll
    "{icon:doc.text.fill} Compiling project with 247 source files... this might take a while, grab a coffee"
    "The quick brown fox jumps over the lazy dog — testing long text scrolling behavior in the menu bar toast"
    "{color:green}**SUCCESS:**{/color} All 1,847 tests passed in 23.4s across 12 test suites with 0 failures and 0 skipped"
    "{color:green}{icon:server.rack}{/color} Deploy: {color:green}build{/color} → {color:green}test{/color} → {color:green}staging{/color} → {color:orange}**production (pending)**{/color}"
    "{color:red}{icon:exclamationmark.triangle.fill}{/color} {color:red}**Alert:**{/color} CPU at 98% on prod-03, auto-scaling triggered, 2 new instances spinning up"
    "{color:blue}{icon:arrow.down.circle.fill}{/color} Downloading **node_modules** — 1,247 packages, {color:orange}**342 MB**{/color} remaining..."
    "{color:purple}{icon:sparkles}{/color} {color:purple}**Claude:**{/color} I've refactored the authentication module and added comprehensive test coverage for all edge cases"
)

idx=$((RANDOM % ${#messages[@]}))
msg="${messages[$idx]}"
echo "Testing: $msg"
./MenubarToast "$msg"
