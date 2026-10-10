# Authentication emails

Both templates were deployed to the Juggle Dude Supabase project on 2026-10-09 and updated to Universal Links later that evening. Custom SMTP uses Amazon SES in `eu-north-1`; see [email delivery status](../../docs/auth-setup.md#email-delivery) for the remaining sandbox restriction.

| Supabase template | Subject | Source |
| --- | --- | --- |
| Magic Link or OTP | Your Juggle Dude sign-in link | `magic-link.html` |
| Confirm sign up | Welcome to Juggle Dude — confirm your email | `confirm-sign-up.html` |

When updating a template, select and delete the entire existing source before pasting the complete HTML document into the matching Supabase Authentication → Email template. Check Preview before saving: the editor can append pasted text to existing content.

Reload the dashboard after saving and verify the next delivered email's actual destination without opening or exposing its token. Supabase Auth caches email templates (the upstream default is 10 minutes), so a saved preview is not proof that delivery has switched. At 23:53 on 2026-10-09, a delivered message still used the old verification link after the dashboard update. The next inspected message, delivered at 00:00 on 2026-10-10, contained the new domain, path, PKCE fragment token and magic-link type. No token was consumed during this check; the user still needs to confirm device opening and sign-in.

The buttons use `https://juggledude.com/auth/email/#token_hash={{ .TokenHash }}&type=magiclink` and `type=signup`, respectively (HTML uses `&amp;`). iOS associates this route with the signed `com.juggledude` app. The app constructs a verification request to its configured Supabase project, stops the redirect, and passes the resulting callback to the Auth SDK for the original PKCE code exchange. Verification stays inside the app. The fragment keeps the token out of website request logs and browser referrers.

Do not change these links to `{{ .SiteURL }}`. Returning to `{{ .ConfirmationURL }}` restores the legacy browser → custom-scheme flow and its possible app-opening confirmation. The original `juggledude://auth/callback` remains supported for Google and older emails. The web fallback never verifies or consumes a token; its explicit custom-scheme button may still show a browser confirmation. Email-client wrappers and user link preferences can affect Universal Link behavior.

Keep provider click/open tracking off for authentication mail. The templates include no tracking pixels, third-party fonts, or external images. Initiate and complete a device test in the same Juggle Dude installation because the app uses PKCE. A browser preview alone cannot test the authentication exchange.

SMTP credentials belong only in Supabase's SMTP configuration, never in these templates, the iOS app, or Git.
