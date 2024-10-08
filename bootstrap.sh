#!/bin/bash

set -e

app=$1
current_directory=$(pwd)
backend_directory="electron-backend"
npm install electron electron-vite --save-dev
npm create @quick-start/electron ${app} -- --template vue


cd ${app}
npm install

npm install element-plus
npm install thrift
npm install unocss
npm install @unocss/reset
npm install @iconify/json


cat <<'EOF' > "${current_directory}/${app}/src/renderer/uno.config.ts"
import {
  defineConfig,
  presetAttributify,
  presetIcons,
  presetTypography,
  presetUno,
  presetWebFonts,
  transformerDirectives,
  transformerVariantGroup
} from 'unocss'

export default defineConfig({
  shortcuts: [
    // ...
  ],
  theme: {
    colors: {
      // ...
    }
  },
  presets: [
    presetUno(),
    presetAttributify(),
    presetIcons(),
    presetTypography(),
    presetWebFonts({
      fonts: {
        // ...
      }
    })
  ],
  transformers: [transformerDirectives(), transformerVariantGroup()]
})
EOF

cat <<'EOF' > "${current_directory}/${app}/src/main/build.js"
const fs = require('fs')
const path = require('path')

const source = path.resolve(__dirname, 'gen-nodejs')
const destination = path.resolve(__dirname, '../../gen-nodejs')

// 递归创建目录
fs.mkdirSync(destination, { recursive: true })

// 复制文件
fs.readdirSync(source).forEach((file) => {
  fs.copyFileSync(path.join(source, file), path.join(destination, file))
})

console.log('Files copied successfully!')
EOF

cat <<'EOF' > "${current_directory}/${app}/src/main/hello.thrift"

namespace js api

struct Request {
	1: string message
}

struct Response {
	1: string message
}

service Service {
    Response echo(1: Request req)
}

EOF

cd "${current_directory}/${app}/src/main" && thrift -r --gen js:node hello.thrift
mv "${current_directory}/${app}/src/main/gen-nodejs" "${current_directory}/${app}/gen-nodejs"

cat <<'EOF' > "${current_directory}/${app}/src/main/rpc.js"
const thrift = require('thrift')
const hello = require('../../gen-nodejs/Service')
const ttypes = require('../../gen-nodejs/hello_types')
const util = require('util')

const connection = thrift.createConnection('localhost', 8888, {
  transport: thrift.TBufferedTransport,
  protocol: thrift.TBinaryProtocol
})

const client = thrift.createClient(hello, connection)
const echoAsync = util.promisify(client.echo.bind(client))

function echo() {
  const request = new ttypes.Request({ message: 'Hello, Thrift!' })
  const r = (async () => {
    try {
      const response = await echoAsync(request)
      console.log('服务器响应:', response)
      return response
    } catch (err) {
      console.error('请求错误:', err)
    }
  })()
  return r
}

export { echo }

EOF

cat <<'EOF' > "${current_directory}/${app}/src/main/index.js"
import { app, shell, BrowserWindow, ipcMain } from 'electron'
import { join } from 'path'
const { exec } = require('child_process')
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import icon from '../../resources/icon.png?asset'
import { echo } from './rpc.js'
const path = require('path')

function createWindow() {
  // Create the browser window.
  const mainWindow = new BrowserWindow({
    width: 900,
    height: 670,
    show: false,
    autoHideMenuBar: true,
    ...(process.platform === 'linux' ? { icon } : {}),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow.show()
  })

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  // HMR for renderer base on electron-vite cli.
  // Load the remote URL for development or the local html file for production.
  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

// This method will be called when Electron has finished
// initialization and is ready to create browser windows.
// Some APIs can only be used after this event occurs.
let goService

// 处理关闭事件
app.on('will-quit', () => {
  if (goService) {
    goService.kill() // 关闭 Go 服务
  }
})
app.whenReady().then(() => {
  let backendService = path.join(__dirname, '../../binary/electron-backend')
  goService = exec(backendService, (error, stdout, stderr) => {
    if (error) {
      console.error(`执行错误: ${error}`)
      return
    }
    console.log(`stdout: ${stdout}`)
    console.error(`stderr: ${stderr}`)
  })

  // Set app user model id for windows
  electronApp.setAppUserModelId('com.electron')

  // Default open or close DevTools by F12 in development
  // and ignore CommandOrControl + R in production.
  // see https://github.com/alex8088/electron-toolkit/tree/master/packages/utils
  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  // 主进程中，处理请求并回应
  ipcMain.handle('message-channel', async (event, data) => {
    return echo(data)
  })

  createWindow()

  app.on('activate', function () {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

// Quit when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

// In this file you can include the rest of your app"s specific main process
// code. You can also put them in separate files and require them here.
EOF


cat <<'EOF' > "${current_directory}/${app}/src/renderer/src/main.js"
import './assets/main.css'

import { createApp } from 'vue'
import App from './App.vue'
import '@unocss/reset/tailwind.css'
import 'uno.css'

import ElementPlus from 'element-plus'

import 'element-plus/dist/index.css'

createApp(App).use(ElementPlus).mount('#app')
EOF

cat <<'EOF' > "${current_directory}/${app}/src/renderer/src/App.vue"
<script setup>
import { ref } from 'vue'
import Versions from './components/Versions.vue'

const data = ref('')

const ipcHandle = () => {
  window.electron.ipcRenderer.invoke('message-channel', '数据').then((response) => {
    console.log('主进程回应数据:', response)
    data.value = response
  })
}
</script>

<template>
  <div>
    <div text-center text-red>测试UNOCSS数据</div>
  </div>
  <img alt="logo" class="logo" src="./assets/electron.svg" />
  <div class="creator">Powered by electron-vite</div>
  <div class="text">
    Build an Electron app with
    <span class="vue">Vue</span>
  </div>
  <p class="tip">Please try pressing <code>F12</code> to open the devTool</p>
  <div class="actions">
    <div class="action">
      <a href="https://electron-vite.org/" target="_blank" rel="noreferrer">Documentation</a>
    </div>
    <div class="action">
      <el-button type="primary" @click="ipcHandle">Send IPC</el-button>
      <div>{{ data }}</div>
    </div>
  </div>
  <Versions />
</template>
EOF

cat <<'EOF' > "${current_directory}/${app}/electron.vite.config.mjs"
import { resolve } from 'path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'
import vue from '@vitejs/plugin-vue'
import unocss from 'unocss/vite'

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()]
  },
  preload: {
    plugins: [externalizeDepsPlugin()]
  },
  renderer: {
    resolve: {
      alias: {
        '@renderer': resolve('src/renderer/src')
      }
    },
    plugins: [vue(), unocss()]
  }
})
EOF

cat <<'EOF' > "${current_directory}/${app}/src/renderer/src/App.vue"
<script setup>
import { ref } from 'vue'
import Versions from './components/Versions.vue'

const data = ref('')

const ipcHandle = () => {
  window.electron.ipcRenderer.invoke('message-channel', '数据').then((response) => {
    console.log('主进程回应数据:', response)
    data.value = response
  })
}
</script>

<template>
  <div>
    <div text-center text-red>测试UNOCSS数据</div>
  </div>
  <img alt="logo" class="logo" src="./assets/electron.svg" />
  <div class="creator">Powered by electron-vite</div>
  <div class="text">
    Build an Electron app with
    <span class="vue">Vue</span>
  </div>
  <p class="tip">Please try pressing <code>F12</code> to open the devTool</p>
  <div class="actions">
    <div class="action">
      <a href="https://electron-vite.org/" target="_blank" rel="noreferrer">Documentation</a>
    </div>
    <div class="action">
      <el-button type="primary" @click="ipcHandle">Send IPC</el-button>
      <div>{{ data }}</div>
    </div>
  </div>
  <Versions />
</template>
EOF

mkdir -p "${current_directory}/${app}/binary"
mkdir -p "${current_directory}/${app}/${backend_directory}"
cd "${current_directory}/${app}/${backend_directory}"

go mod init electron-backend

cat <<'EOF' > "${current_directory}/${app}/${backend_directory}/hello.thrift"
// hello.thrift
namespace go hello

struct Request {
	1: string message
}

struct Response {
	1: string message
}

service Service {
    Response echo(1: Request req)
}
EOF
go install github.com/cloudwego/kitex/tool/cmd/kitex@latest || echo 'already install kitex'
go install github.com/cloudwego/thriftgo@latest || echo 'already install thriftgo'
kitex -module electron-backend -service hello  hello.thrift

cat <<'EOF' > "${current_directory}/${app}/${backend_directory}/handler.go"
package main

import (
	"context"

	"electron-backend/kitex_gen/hello"
)

// ServiceImpl implements the last service interface defined in the IDL.
type ServiceImpl struct{}

// Echo implements the ServiceImpl interface.
func (s *ServiceImpl) Echo(ctx context.Context, req *hello.Request) (resp *hello.Response, err error) {
	resp = hello.NewResponse()
	resp.Message = req.Message + ", response"
	return
}
EOF

cat <<'EOF' > "${current_directory}/${app}/${backend_directory}/main.go"
package main

import (
	"log"
	"electron-backend/kitex_gen/hello/service"
)

func main() {
	svr := service.NewServer(new(ServiceImpl))
	err := svr.Run()
	if err != nil {
		log.Println(err.Error())
	}
}
EOF

go mod tidy && go build . && mv electron-backend "${current_directory}/${app}/binary"


mkdir -p "${current_directory}/${app}/${backend_directory}/client"
cat <<'EOF' > "${current_directory}/${app}/${backend_directory}/client/main.go"
package main

import (
	"context"
	"fmt"
	"log"

	kclient "github.com/cloudwego/kitex/client"

	"electron-backend/kitex_gen/hello"
	"electron-backend/kitex_gen/hello/service"
)

func main() {
	client, err := service.NewClient("Service", kclient.WithHostPorts("127.0.0.1:8888"))
	if err != nil {
		log.Fatal(err)
	}

	req := hello.NewRequest()
	req.Message = "hello"
	resp, err := client.Echo(context.Background(), req)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println(resp)
}
EOF


#cd "${current_directory}/${app}" && npm run dev