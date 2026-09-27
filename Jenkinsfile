// =============================================================================
//  mall 微服务 CI/CD 流水线
//
//  Jenkins → Maven 构建 → 镜像构建 → 推送 Harbor → K8s 滚动更新
//
//  ── 设计前提 ──────────────────────────────────────────────────────────────
//  · 服务【首次创建】是手动做的（kubectl apply -f mall-k8s/1x-xxx.yaml）
//    本流水线只负责【更新镜像】，不做 apply / create
//  · 镜像 tag = <commit短SHA>[-dirty]-<BUILD_NUMBER>
//    每次构建都唯一 → kubectl set image 一定能触发滚动更新
//    （用固定 tag 时 k8s 会认为镜像没变，不滚动）
//
//  ── 运行前必须满足的前置条件 ────────────────────────────────────────────
//  1) jenkins 用户加入 docker 组（否则所有 docker 命令 permission denied）
//       sudo usermod -aG docker jenkins
//       sudo systemctl restart jenkins
//  2) 本机装 kubectl，且 jenkins 家目录有 kubeconfig（否则最后一步没法执行）
//       # 装 kubectl（阿里云源，GitHub/dl.k8s.io 可能被墙）
//       sudo apt-get install -y apt-transport-https ca-certificates curl gpg
//       curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/deb/Release.key \
//         | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
//       echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/deb/ /" \
//         | sudo tee /etc/apt/sources.list.d/kubernetes.list
//       sudo apt-get update && sudo apt-get install -y kubectl
//       # 从 master 拷 kubeconfig
//       sudo mkdir -p /var/lib/jenkins/.kube
//       sudo cp <从 master 拿到的 admin.conf> /var/lib/jenkins/.kube/config
//       sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube
//       sudo chmod 600 /var/lib/jenkins/.kube/config
//  3) Jenkins 凭据 harbor-passport 存在（用户名/密码类型）
//     Jenkins job 的 SCM 用 github-pvt 私钥
//
//  ── 关于 Dockerfile ──────────────────────────────────────────────────────
//  仓库里的 <module>/dockerfile 目前【没有提交到 git】，Jenkins 每次是新 clone，
//  工作区里不会有它们，所以这里用 writeFile 直接生成，让流水线自包含。
//  更好的做法是把 Dockerfile 提交进仓库，那样就不用在 Jenkinsfile 里生成了。
// =============================================================================

pipeline {
  agent any

  options {
    timestamps()
    skipDefaultCheckout(true)
    disableConcurrentBuilds()        // 这台机器只有 1.9GB 内存，绝对不能并发
    timeout(time: 90, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    choice(name: 'MODULE',
           choices: ['mall-admin', 'mall-search', 'mall-portal', 'mall-demo'],
           description: '要构建并更新的服务')
    string(name: 'REGISTRY',       defaultValue: '192.168.203.120:80', description: 'Harbor 地址')
    string(name: 'HARBOR_PROJECT', defaultValue: 'mall',               description: 'Harbor 项目名')
    string(name: 'NAMESPACE',      defaultValue: 'mall',               description: 'K8s 命名空间')
    booleanParam(name: 'DO_DEPLOY', defaultValue: true,                description: '是否执行 K8s 滚动更新')
  }

  environment {
    MVN            = '/usr/share/maven/bin/mvn'
    MAVEN_OPTS     = '-Xmx512m -XX:+UseSerialGC'
    APP_VERSION    = '1.0-SNAPSHOT'
    BASE_IMAGE     = 'eclipse-temurin:17-jre-jammy'
    // 参数转成环境变量，sh 里用 $VAR 更直观
    MODULE         = "${params.MODULE}"
    REGISTRY_ADDR  = "${params.REGISTRY}"
    HARBOR_PROJECT = "${params.HARBOR_PROJECT}"
    NAMESPACE      = "${params.NAMESPACE}"
  }

  stages {

    // ------------------------------------------------------------- 1 ------
    stage('拉取代码') {
      steps {
        checkout([$class: 'GitSCM',
          branches: [[name: '*/master']],
          userRemoteConfigs: [[
            url: 'git@github.com:moyu-777/mall.git',
            credentialsId: 'github-pvt'
          ]],
          extensions: [
            // 浅克隆 + 放宽超时：这个网络拉全量历史很慢（之前就是撞了默认 10 分钟超时）
            [$class: 'CloneOption', shallow: true, depth: 1, noTags: true, timeout: 30],
            [$class: 'CleanCheckout']
          ]
        ])
      }
    }

    // ------------------------------------------------------------- 2 ------
    stage('计算镜像 tag') {
      steps {
        script {
          def sha   = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          def dirty = sh(script: 'git status --porcelain | head -1 || true', returnStdout: true).trim()
          env.IMAGE_TAG  = sha + (dirty ? '-dirty' : '') + '-' + env.BUILD_NUMBER
          env.FULL_IMAGE = "${params.REGISTRY}/${params.HARBOR_PROJECT}/${params.MODULE}:${env.IMAGE_TAG}"
          echo "代码版本 : ${sha}"
          echo "完整镜像 : ${env.FULL_IMAGE}"
        }
      }
    }

    // ------------------------------------------------------------- 3 ------
    stage('Maven 构建') {
      steps {
        // -Ddocker.skip=true 跳过 pom 里那个连远程 daemon 192.168.3.101:2375 的
        // fabric8 docker-maven-plugin，否则 package 阶段必然失败
        // -pl <module> -am 只构建目标模块和它依赖的库模块
        sh "$MVN -B -DskipTests -Ddocker.skip=true -pl $MODULE -am clean package"
      }
      post {
        success {
          archiveArtifacts artifacts: "${params.MODULE}/target/*.jar",
                           fingerprint: true, allowEmptyArchive: true
        }
      }
    }

    // ------------------------------------------------------------- 4 ------
    stage('构建镜像') {
      steps {
        writeFile file: "${params.MODULE}/Dockerfile", text: """FROM ${BASE_IMAGE}

WORKDIR /app

COPY ./target/${params.MODULE}-${APP_VERSION}.jar /app/app.jar

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
"""
        writeFile file: "${params.MODULE}/.dockerignore", text: """target/*
!target/*.jar
"""
        sh "docker build -t $FULL_IMAGE -f $MODULE/Dockerfile $MODULE/"
        sh "docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep $MODULE || true"
      }
    }

    // ------------------------------------------------------------- 5 ------
    stage('推送 Harbor') {
      steps {
        withCredentials([usernamePassword(
            credentialsId: 'harbor-passport',
            usernameVariable: 'HARBOR_USER',
            passwordVariable: 'HARBOR_PASS')]) {
          sh '''
            set -e
            echo "$HARBOR_PASS" | docker login "$REGISTRY_ADDR" -u "$HARBOR_USER" --password-stdin
            docker push "$FULL_IMAGE"
            docker logout "$REGISTRY_ADDR" || true
          '''
        }
      }
    }

    // ------------------------------------------------------------- 6 ------
    stage('K8s 滚动更新') {
      when { expression { return params.DO_DEPLOY } }
      steps {
        sh '''
          set -e

          if ! kubectl -n "$NAMESPACE" get deployment "$MODULE" >/dev/null 2>&1; then
            echo "=============================================="
            echo " Deployment/$MODULE 不存在。"
            echo " 按约定，首次创建是手动做的："
            echo "   kubectl apply -f mall-k8s/1x-$MODULE.yaml"
            echo " 本流水线只做「更新镜像」。"
            echo "=============================================="
            exit 1
          fi

          echo "=== 更新前 ==="
          kubectl -n "$NAMESPACE" get deployment "$MODULE" \
            -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

          kubectl -n "$NAMESPACE" set image deployment/"$MODULE" "$MODULE"="$FULL_IMAGE"

          echo "=== 等待滚动更新完成（最长 5 分钟）==="
          kubectl -n "$NAMESPACE" rollout status deployment/"$MODULE" --timeout=300s

          echo "=== 更新后 ==="
          kubectl -n "$NAMESPACE" get deployment "$MODULE" \
            -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
          kubectl -n "$NAMESPACE" get pods -l app="$MODULE" -o wide
        '''
        script { env.DEPLOY_DONE = 'true' }
      }
    }
  }

  post {
    success {
      echo "✅ ${params.MODULE} 已更新到 ${env.FULL_IMAGE}"
    }
    failure {
      script {
        if (env.DEPLOY_DONE == 'true' && params.DO_DEPLOY) {
          echo "⚠️  部署后失败，回滚到上一个版本"
          sh "kubectl -n ${params.NAMESPACE} rollout undo deployment/${params.MODULE} || true"
        }
      }
    }
    always {
      sh 'docker logout $REGISTRY_ADDR 2>/dev/null || true'
    }
  }
}
