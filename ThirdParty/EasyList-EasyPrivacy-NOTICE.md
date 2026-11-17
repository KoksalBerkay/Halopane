# EasyList and EasyPrivacy

The bundled Safari rules are adapted from EasyList and EasyPrivacy by the EasyList contributors. Source URLs, versions and SHA-256 checksums are listed in [content-rules-info.json](../Resources/content-rules-info.json). This adapted ruleset is distributed under [Creative Commons Attribution-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-sa/3.0/legalcode), one of the options in the [upstream licence](https://easylist.to/pages/licence.html). The browser source is separate from this adapted dataset.

To regenerate with new upstream files:

    ./Verification/convert-content-rules.sh /path/to/easylist.txt /path/to/easyprivacy.txt

Conversion keeps plain domain blockers and domain blockers marked third-party, skips hosts with related exception rules, and blocks only supported third-party subresources. The converter keeps up to 45,000 domain rules, then adds simple ad paths with a combined limit of 49,000. Related exception rules are excluded from the path subset as well. It does not convert cosmetic filters, scriptlets, arbitrary URL patterns, scoped rules, or first-party blocking. The bundled JSON is static at runtime. Lists that users add in the app are stored on their device and are not distributed with Halopane.
