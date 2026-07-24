## 依赖
1. gtk3
2. vte
3. libserialport
4. luajit
5. nerdfont

## 部署
```sh
cd ~/.config
git clone https://github.com/cnjhb/awesomeWmCfg.git awesome
cd ~/.local/share/glib-2.0/schemas
cp ~/.config/awesome/cn.jhb.awesome.gschema.xml .
glib-compile-schemas .
```
