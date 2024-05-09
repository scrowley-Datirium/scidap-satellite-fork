const path = require('path');
const fs = require('fs');
const child_process = require('child_process');
const os = require('os');
const url = require('url');
const process = require('process');


function loadSettings(settings_locations){
  for (location of settings_locations){
    try {
      settings = JSON.parse(fs.readFileSync(location));
      console.log(`Successfully loaded settings from ${location}`);
      settings.loadedFrom = location;                                // need to know from which file we loaded these settings
      break;
    } catch (e) {
      console.log(`Failed to load settings from ${location}`);
    }
  };
  // in case systemRoot was set as a relative path, we need to resolve it based on the homedir
  settings.satelliteSettings.systemRoot = path.resolve(os.homedir(), settings.satelliteSettings.systemRoot);
  // in case defaultLocations were set as a relative path,
  // we need to resolve them based on settings.satelliteSettings.systemRoot
  settings.defaultLocations = getDefaultLocations(settings);
  // resolve relative path in each collection from localfiles remote
  if (settings.satelliteSettings.remotes) {
    if (settings.satelliteSettings.remotes.localfiles &&
        settings.satelliteSettings.remotes.localfiles.collection &&
        settings.satelliteSettings.remotes.localfiles.collection.length > 0) {
      for (collection of settings.satelliteSettings.remotes.localfiles.collection) {
        collection.path = path.resolve(settings.satelliteSettings.systemRoot, collection.path)
      }
    }
  };
  return settings;
}


function getDefaultLocations(settings){
  const defaultLocations = {};
  for (const [key, value] of Object.entries(settings.defaultLocations)) {
    defaultLocations[key] = path.resolve(settings.satelliteSettings.systemRoot, value)
  };
  return defaultLocations
}


function getAria2cArgs(settings){
  let aria2cArgs = {
    ...settings.aria2cSettings,
    "--enable-rpc": true,
    "--rpc-listen-all": false,
    "--rpc-listen-port": settings.satelliteSettings.aria2cPort
  };
  if (settings.satelliteSettings.proxy) {
    aria2cArgs["--all-proxy"] = settings.satelliteSettings.proxy;
  };
  return Object.keys(aria2cArgs).map((key) => `${key}=${aria2cArgs[key]}`);  // to return as array of "key=value"
}

function getClusterEnvVar(settings){
  const clusterEnvVar = {
    PATH: settings.executables.pathEnvVar,
    OUTPUT_DIR: settings.clusterApiSettings.outputDir,
    SCRIPT_DIR: settings.clusterApiSettings.scriptDir,
    TMP_TOIL_DIR: settings.clusterApiSettings.tmpToilDir,
    ENV_FILE_PATH: settings.clusterApiSettings.envFilePath,
    SINGULARITY_TMP_DIR: settings.clusterApiSettings.singularityTmpPath,
    CWL_SINGULARITY_DIR: settings.clusterApiSettings.cwlSingularityPath,
    NJS_CLIENT_PORT: settings.satelliteSettings.port,
    BATCH_SYSTEM_TOIL: settings.clusterApiSettings.batchSystem, 
    NUM_CPUS: settings.clusterApiSettings.numCpus, 
    MAX_MEM: settings.clusterApiSettings.maxMem, 
    SATELLITE_ROOT: settings.satelliteSettings.systemRoot + "/"
  };
  return clusterEnvVar
}

function getAirflowEnvVar(settings){
  const airflowEnvVar = {
    PATH: settings.executables.pathEnvVar,
    AIRFLOW_HOME: settings.defaultLocations.airflow,
    PROCESS_REPORT_URL: `http://127.0.0.1:${settings.satelliteSettings.port}`,
    AIRFLOW__CORE__SQL_ALCHEMY_CONN: `postgresql+psycopg2://${settings.databaseSettings.db_user}:${settings.databaseSettings.db_password}@127.0.0.1:${settings.databaseSettings.db_port}/${settings.databaseSettings.db_name}`,
    LC_ALL: 'en_US.UTF-8',
    LANG: 'en_US.UTF-8'
  };
  for (key in settings.airflowSettings){
    [section, parameter] = key.split("__");
    airflowEnvVar[`AIRFLOW__${section.toUpperCase()}__${parameter.toUpperCase()}`] = settings.airflowSettings[key];
  };
  return airflowEnvVar
}

function getNjsClientEnvVar(settings){

  const njsClientSettingsLocation = path.resolve(    // we want to dynamically rectreate NJS-Client settings file, because from Electron App we read token after we read settings
    path.dirname(settings.loadedFrom),               // keep NJS-Client settings alognside the file from where we loaded main settings
    'njs_client_settings.json'
  )
  saveNjsClientSettings(settings, njsClientSettingsLocation);

  let njsClientEnvVar = {
    PATH: settings.executables.pathEnvVar,
    SSL_CONN: settings.satelliteSettings.enableSSL,
    SSL_API_SYNC: true,
    API_URL: settings.satelliteSettings.rcServer,
    SATELLITE_TOKEN: settings.satelliteSettings.rcServerToken,
    CONFIG_FILE: njsClientSettingsLocation,
    NODE_OPTIONS: '--trace-warnings --pending-deprecation'   // why do we need it? Should be keep it for NestJS too?
  };
  if (settings.satelliteSettings.proxy) {
    njsClientEnvVar = {
      ...njsClientEnvVar,
      https_proxy: settings.satelliteSettings.proxy,
      http_proxy: settings.satelliteSettings.proxy,
      ftp_proxy: settings.satelliteSettings.proxy,
      no_proxy: settings.satelliteSettings.noProxy || ''
    };
  };
  return njsClientEnvVar
}


function saveNjsClientSettings(settings, location){
  /*
  settings.satelliteSettings.enableSSL will be used as environment
  variable. Exports settings as json file to the provided location.
  If remotes section of the settings has localfiles field, and
  collection array is not empty, we will try to resolve each path
  based on the systemRoot.
  */

  const njsClientSettings = {
      port: settings.satelliteSettings.port,
      airflowAPIPort: settings.satelliteSettings.airflowAPIPort,
      systemRoot: settings.satelliteSettings.systemRoot + "/"  // patch to avoid bug in NJS-Client (remove if not needed)
  };
  njsClientSettings.download = {
    'aria2': {
      'host': 'localhost',
      'port': settings.satelliteSettings.aria2cPort,
      'secure': false,
      'secret': '',
      'path': '/jsonrpc'
    }
  };
  if (settings.satelliteSettings.remotes) {
    njsClientSettings.remotes = settings.satelliteSettings.remotes;
  };
  fs.writeFileSync(location, JSON.stringify(njsClientSettings), {mode: 0o600});  // creates or overwrites file with -rw------- permissions
}


function waitForInitConfiguration(settings){
  /*
  Creates all required folders.
  Creates airflow.cfg by running airflow with the configured AIRFLOW_HOME (maybe we don't need this step).
  Checks if '~/.ncbi/user-settings.mkfg' exists. If not, creates it.
  Checks if '~/.ncbi/user-settings.mkfg.scidap.backup' exists. If not, creates it.
  Adds or updates proxy configurations in the user-settings.mkfg file based on
  settings.satelliteSettings.
  */

  const folders = [
    settings.satelliteSettings.systemRoot,                            // for node < 10.12.0 recursive won't work, so we need to at least create systemRoot
    ...Object.values(settings.defaultLocations)
  ]
  for (folder of folders) {
    try {
      fs.mkdirSync(folder, {recursive: true});
    } catch (e) {
      console.log(`Failed to create directory ${folder} due to ${e}`);
    }
  }
  // child_process.spawnSync(                         // Need to leave it like this until we make sure that api server is run after scheduler and they both don't create airflow.cfg
  //   "airflow", [],
  //   {
  //     cwd: settings.defaultLocations.airflow,
  //     shell: true,
  //     env: getAirflowEnvVar(settings)
  //   }
  // );
  const ncbi_dir = path.resolve(os.homedir(), '.ncbi')
  const mkfg_file = path.resolve(ncbi_dir, 'user-settings.mkfg')
  const mkfg_file_backup = path.resolve(ncbi_dir, 'user-settings.mkfg.backuped_by_scidap')
  child_process.spawnSync(
    `if [ ! -e ${mkfg_file} ]; then
       echo "Creating ${mkfg_file}"
       mkdir -p ${ncbi_dir}
       touch ${mkfg_file}
     elif [ ! -e ${mkfg_file_backup} ]; then
       echo "Backing up ${mkfg_file} to ${mkfg_file_backup}"
       cp ${mkfg_file} ${mkfg_file_backup}
     fi

     if ! grep -q "/LIBS/GUID" ${mkfg_file}; then
       echo "Adding /LIBS/GUID"
       echo "/LIBS/GUID = '$(uuidgen)'" >> ${mkfg_file}
     fi

     if ! grep -q "/http/proxy/enabled" ${mkfg_file}; then
       echo "Adding proxy settings"
       echo "/http/proxy/enabled = '${settings.satelliteSettings.proxy?true:false}'" >> ${mkfg_file}
     else
       echo "Updating proxy settings"
       sed -i -e "s/^\\/http\\/proxy\\/enabled.*/\\/http\\/proxy\\/enabled = '${settings.satelliteSettings.proxy?true:false}'/g" ${mkfg_file}
     fi

     if ! grep -q "/http/proxy/path" ${mkfg_file}; then
       echo "Adding proxy path"
       echo "/http/proxy/path = '${settings.satelliteSettings.proxy?url.parse(settings.satelliteSettings.proxy).host:""}'" >> ${mkfg_file}
     else
       echo "Updating proxy path"
       sed -i -e "s/^\\/http\\/proxy\\/path.*/\\/http\\/proxy\\/path = '${settings.satelliteSettings.proxy?url.parse(settings.satelliteSettings.proxy).host:""}'/g" ${mkfg_file}
     fi`,
    [],
    {
      cwd: settings.satelliteSettings.systemRoot,
      shell: true,
      env: getAirflowEnvVar(settings)  // we need only PATH from there
    }
  )
}


function getSettings(cwd, customLocation){
  /*
  Relative locations will be resolved based on __dirname if cwd was not provided.
  If customLocation is provided it have higher priority compared to other locations
  */

  cwd = cwd || __dirname;

  // might be different between Ubuntu and macOS
  const settings_locations = [
    process.env.SCIDAP_SETTINGS,
    path.resolve(cwd, '../../scidap_settings.json'),
    path.resolve(cwd, '../../.config/scidap_satellite/scidap_settings.json'),
    path.resolve(os.homedir(), './.config/scidap_satellite/scidap_settings.json'),  // might be different on mac
    path.resolve(cwd, '../configs/scidap_default_settings.json')                    // default settings should be always present
  ];

  if (customLocation){
    settings_locations.unshift(customLocation);
  };

  // might be different between Ubuntu and macOS
  // Load settings from the external file, add dynamically configured locations for executables
  const settings = {
    ...loadSettings(settings_locations),
    executables: {
      startClusterApi: path.resolve(cwd, '../satellite/bin/start_cluster_api.sh'),
      aria2c: path.resolve(cwd, '../satellite/bin/aria2c'),
      startPostgres: path.resolve(cwd, '../satellite/bin/start_postgres.sh'),
      startScheduler: path.resolve(cwd, '../satellite/bin/start_scheduler.sh'),
      startApiserver: path.resolve(cwd, '../satellite/bin/start_apiserver.sh'),
      startWebserver: path.resolve(cwd, '../satellite/bin/start_webserver.sh'),
      startNjsClient: path.resolve(cwd, '../satellite/dist/src/main.js'),
      satelliteBin: path.resolve(cwd, '../satellite/bin'),                       // not used directly, but added just in case
      // cwlAirflowBin: path.resolve(cwd, '../cwl-airflow/bin_portable'),
      clusterBin: path.resolve(cwd, '../cluster_api/bin_portable'),
      pathEnvVar: `${ path.resolve(cwd, '../satellite/bin') }:${ path.resolve(cwd, '../cluster_api/bin_portable') }:/usr/bin:/bin:/usr/local/bin:/usr/sbin:${process.env.PATH}`  // maybe add to the original PATH to make it universal, might be different on mac
    }
  }

  return settings;
}


function getRunConfiguration(settings){

  const configuration = {
    apps: [
      {
        name: 'aria2c',
        script: settings.executables.aria2c,
        args: getAria2cArgs(settings),
        watch: false,
        exec_mode: 'fork_mode',
        cwd: settings.defaultLocations.airflow
      },
      {
        name: 'cluster-api',
        script: settings.executables.startClusterApi,
        interpreter: 'bash',
        watch: false,
        exec_mode: 'fork_mode',
        cwd: settings.defaultLocations.clusterApi,
        env: getClusterEnvVar(settings)
      },  
      {
        name: 'njs-client',
        script: settings.executables.startNjsClient,
        interpreter: 'node',
        watch: false,
        exec_mode: 'fork_mode',
        cwd: settings.defaultLocations.airflow,
        env: getNjsClientEnvVar(settings)
      }
    ]
  };

  return configuration;
}


module.exports = {
  waitForInitConfiguration: waitForInitConfiguration,
  getSettings: getSettings,
  getRunConfiguration: getRunConfiguration
}