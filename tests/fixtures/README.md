# Fixtures

## `gp-saml-gui-*.out`

What `gp-saml-gui` prints on standard output when a SAML exchange succeeds, for
the three shapes a GlobalProtect portal can produce. Captured from the real tool
(Ubuntu package `gp-saml-gui`) driven against `fake-idp.py`, not hand-written.

`HOST` carries two facts at once: the server the exchange actually authenticated
against, which may differ from the one first contacted, and which credential kind
came back, as the `<interface>:<cookie-name>` path. Neither may be assumed - see
`openspec/changes/add-sso-auth-mode/`.

## `fake-idp.py`

Stands in for the identity provider's final response by serving the headers
`gp-saml-gui` looks for (`saml-username` plus `prelogin-cookie` or
`portal-userauthcookie`). It makes the whole extraction path exercisable with no
corporate account, no real portal, and no network beyond loopback.

    tests/fixtures/fake-idp.py 18801 prelogin-cookie &
    gp-saml-gui -u -g http://127.0.0.1:18801/

With a third argument it answers `/` with a redirect, which reproduces an
exchange that lands on a different server than the one first contacted:

    tests/fixtures/fake-idp.py 18803 prelogin-cookie http://127.0.0.1:18804/final &
    tests/fixtures/fake-idp.py 18804 prelogin-cookie &
    gp-saml-gui -u -g http://127.0.0.1:18803/

Cookie values in the captures are synthetic. Nothing here is a real credential.
