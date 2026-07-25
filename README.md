<h2 align="center">
    <a href="https://httpie.io" target="blank_">
        <img height="100" alt="nullplatform" src="https://nullplatform.com/favicon/android-chrome-192x192.png" />
    </a>
    <br>
    <br>
    Nullplatform "Any Technology" Template
    <br>
</h2>

This is a minimalistic sample on how you can create an application on arbitrary technology.
In particular, we're spinning up an image that contains an echo server.
You can check *Echo Server* documentation [here](https://ealenn.github.io/Echo-Server/).

## How do I modify this template to build my own application?

1. Change the Dockerfile to run the application / binary that you are building
2. Deploy your application in nullplatform

## Services in this repo

- [`aurora-postgres-server`](aurora-postgres-server/README.md) — provisions an Aurora PostgreSQL cluster (writer + configurable readers) in AWS.
- [`aurora-postgres-db`](aurora-postgres-db/README.md) — provisions a logical PostgreSQL database + per-link grants inside an existing `aurora-postgres-server` cluster.
