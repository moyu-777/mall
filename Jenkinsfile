pipeline {
    agent any
    stages {
        stage('拉取代码') {
            steps {
                git branch: 'master',
                    credentialsId: 'github-ssh',
                    url: 'git@github.com:moyu-777/ruoyi-cloud.git'
            }
        }
        stage('构建') {
            steps {
                sh 'ls -la'
                // 后续添加 Maven 构建、Docker 打包等
            }
        }
    }
}

