# Ad blocking

## 🛡️ Turn blocking on or off

On the phone, open **More (⋯) → Ad blocking**. You can also find it at the top of **Settings**. **Block ads** turns everything on or off. The bundled EasyList and EasyPrivacy list and each list you add have their own switches. Changes apply to screens already open; reload a page to see the full effect.

To turn blocking off for one site, use that screen's toolbar menu. To turn it back on, use the same menu or remove the entry under **Sites with blocking off**.

## 📥 Add or update a list

Choose **Add from Files**, or paste an HTTPS address and tap **Add HTTPS list**. Halopane accepts UTF-8 EasyList or Adblock Plus text and WebKit content-blocker JSON. Lists from the web download only when you add them or tap **Update**. If an update fails, the old list stays active.

You can keep up to 10 added lists. A list may contain up to 16 MiB of source data and 150,000 converted rules, the limit in [WebKit's content blocker](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionParser.cpp#L290-L303). Added lists together can take up to 64 MiB of source data. Larger lists are rejected rather than cut. Downloads have a 20-second timeout and must stay on HTTPS, including through redirects.

## ✏️ Write a rule

Under **My rules → Edit rules**, write one Adblock Plus rule per line, or use the shortcuts to block a domain or hide an element by CSS selector. Tap **Save rules** when done. For example:

| Rule | What it does |
|---|---|
| `\|\|ads.example.com^` | Block requests to a domain and its subdomains. |
| `\|\|example.com/ads/banner.js$script` | Block a script with a matching host and path. |
| `\|\|ads.example.com^$third-party,domain=example.org` | Limit the block to third-party requests on a specified site. |
| `example.com##.sponsored` | Hide matching elements on that site. |
| `@@\|\|ads.example.com/allow.js` | Allow a matching request against rules in the same list. |

Halopane understands anchored domains, literal host and path patterns, supported resource types, first- or third-party restrictions, simple domain scopes, plain CSS selectors and supported network exceptions. A [WebKit JSON example](../Examples/site-ad-rules.json) is also available.

Halopane skips rules it cannot translate faithfully. These include scriptlets, procedural selectors, cosmetic exceptions, arbitrary regular expressions in Adblock Plus text, mixed include and exclude scopes, and options the converter does not support. Check the import summary for counts and examples. The editor marks unsupported rules as you type.

An exception such as `@@` only cancels rules within its own list. An exception in **My rules** cannot undo a rule in the bundled list or one you imported. Use the site switch to turn off all blocking on that site.

## 💾 Back up or restore settings

Tap **Export settings backup** to save your settings, your rules and copies of the lists. **Import settings backup** replaces those settings without downloading anything. The file can contain private list addresses, custom rules and site exceptions; check it before sharing. The shared report leaves out added list names, addresses and rule text.

Use **Remove** beside a list to delete it, or **Reset to defaults** to remove added lists, custom rules and site exceptions.
