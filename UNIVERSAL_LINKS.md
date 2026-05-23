# iOS Universal Links

The iOS target includes the Associated Domains entitlement:

```text
applinks:sakuraonseeker.com
```

For universal links to work on device, the domain must serve an Apple App Site Association file at:

```text
https://sakuraonseeker.com/.well-known/apple-app-site-association
```

That file must include this app's Apple Team ID and bundle identifier:

```text
<TEAM_ID>.com.millw14.sakura
```

Keep the served `paths` aligned with Sakura share routes such as `/anime/*`, `/title/*`, and `/novel/*`.
