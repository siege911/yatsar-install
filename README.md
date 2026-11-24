# yatsar-install

The installer for a Yatsar server. It holds no secret: the images it pulls are private and need a registry token.

```sh
curl -fsSL https://raw.githubusercontent.com/siege911/yatsar-install/main/install.sh | sudo bash
```

It asks what the server is, its hostnames, the first Admin password, the Hub URL and the registry token.

To read it before running it:

```sh
curl -fsSLO https://raw.githubusercontent.com/siege911/yatsar-install/main/install.sh
less install.sh
sudo bash install.sh
```

After the install, update the server with `yatsar update`.
