import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { I18n, LangCode } from '../common/I18n';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint } from '../service/gateway/GatewayModels';
import { LogService } from '../common/LogService';

const TAG = 'LoginPage';
const LOGIN_TIMEOUT_MS = 10000;
const DEFAULT_PORT = 18789;

interface ParsedAddress {
  host: string;
  port: number;
}

interface SavedCredentials {
  host: string;
  port: string;
  token: string;
  password: string;
}

@Entry
@Component
struct LoginPage {
  // Sign Up fields
  @State address: string = '';
  @State token: string = '';
  @State newPassword: string = '';
  @State confirmPassword: string = '';
  // Sign In fields
  @State password: string = '';
  // Common
  @State errorMsg: string = '';
  @State isConnecting: boolean = false;
  @State isSignUp: boolean = true; // true = Sign Up, false = Sign In
  @State savedAddress: string = ''; // displayed in Sign In mode
  @State @Watch('onLangChange') lang: string = 'zh';
  private langListener: (() => void) | undefined = undefined;
  private stateListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private timeoutId: number = -1;
  private connectResolved: boolean = false;
  // Saved credentials for Sign In mode
  private savedHost: string = '';
  private savedPort: string = '';
  private savedToken: string = '';
  private savedPassword: string = '';

  aboutToAppear(): void {
    this.loadLang();
    this.loadSavedCredentials();
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
  }

  aboutToDisappear(): void {
    this.cleanupListener();
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
  }

  onLangChange(): void {}

  build() {
    Column() {
      Blank()
        .layoutWeight(1)

      // Login card
      Column({ space: 16 }) {
        // Logo / Title
        Text('ClawdBot')
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D2691E')

        Text(this.isSignUp ? I18n.t('login.signUpTitle') : I18n.t('login.signInTitle'))
          .fontSize(15)
          .fontColor('#999999')
          .margin({ bottom: 8 })

        if (this.isSignUp) {
          this.SignUpForm()
        } else {
          this.SignInForm()
        }

        // Error message
        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor('#D32F2F')
            .width('100%')
            .textAlign(TextAlign.Center)
        }

        // Action button
        Button(this.isConnecting
          ? I18n.t('login.connecting')
          : (this.isSignUp ? I18n.t('login.signUpButton') : I18n.t('login.signInButton')))
          .width('100%')
          .height(48)
          .backgroundColor(this.isConnecting ? '#B0B0B0' : '#D2691E')
          .fontColor(Color.White)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .borderRadius(12)
          .enabled(!this.isConnecting)
          .onClick(() => {
            if (this.isSignUp) {
              this.doSignUp();
            } else {
              this.doSignIn();
            }
          })

        // Mode switch link
        Text(this.isSignUp ? I18n.t('login.switchToSignIn') : I18n.t('login.switchToSignUp'))
          .fontSize(13)
          .fontColor('#D2691E')
          .onClick(() => {
            this.errorMsg = '';
            this.isSignUp = !this.isSignUp;
          })
      }
      .width('100%')
      .padding(28)
      .margin({ left: 24, right: 24 })
      .backgroundColor(Color.White)
      .borderRadius(16)
      .shadow({
        radius: 20,
        color: '#1A000000',
        offsetX: 0,
        offsetY: 4,
      })

      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SignUpForm() {
    // Address
    Column({ space: 6 }) {
      Text(I18n.t('login.address'))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .width('100%')
      TextInput({ text: $$this.address, placeholder: I18n.t('login.addressPlaceholder') })
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .enabled(!this.isConnecting)
    }
    .width('100%')

    // Token
    Column({ space: 6 }) {
      Text(I18n.t('login.token'))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .width('100%')
      TextInput({ text: this.token, placeholder: I18n.t('login.tokenPlaceholder') })
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .type(InputType.Password)
        .onChange((v: string) => { this.token = v; })
        .enabled(!this.isConnecting)
    }
    .width('100%')

    // New password
    Column({ space: 6 }) {
      Text(I18n.t('login.setPassword'))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .width('100%')
      TextInput({ text: this.newPassword, placeholder: I18n.t('login.setPasswordPlaceholder') })
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .type(InputType.Password)
        .onChange((v: string) => { this.newPassword = v; })
        .enabled(!this.isConnecting)
    }
    .width('100%')

    // Confirm password
    Column({ space: 6 }) {
      Text(I18n.t('login.confirmPassword'))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .width('100%')
      TextInput({ text: this.confirmPassword, placeholder: I18n.t('login.confirmPasswordPlaceholder') })
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .type(InputType.Password)
        .onChange((v: string) => { this.confirmPassword = v; })
        .enabled(!this.isConnecting)
    }
    .width('100%')
  }

  @Builder
  SignInForm() {
    // Show saved address as info
    Row() {
      Text(I18n.t('login.address'))
        .fontSize(14)
        .fontColor('#666666')
      Text(this.savedAddress)
        .fontSize(14)
        .fontColor('#1A1A1A')
        .fontWeight(FontWeight.Medium)
        .margin({ left: 8 })
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#F5F5F5')
    .borderRadius(10)
    .alignItems(VerticalAlign.Center)

    // Password
    Column({ space: 6 }) {
      Text(I18n.t('login.password'))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .width('100%')
      TextInput({ text: this.password, placeholder: I18n.t('login.passwordPlaceholder') })
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .type(InputType.Password)
        .onChange((v: string) => { this.password = v; })
        .enabled(!this.isConnecting)
    }
    .width('100%')
  }

  // ============ Logic ============

  private async loadLang(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'clawdbot_settings');
      let saved = (await store.get('language', 'zh')) as string;
      let lang: LangCode = (saved === 'en') ? 'en' : 'zh';
      I18n.init(lang);
      this.lang = lang;
    } catch {
      I18n.init('zh');
      this.lang = 'zh';
    }
  }

  private async loadSavedCredentials(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      let host = (await store.get('host', '')) as string;
      let port = (await store.get('port', '')) as string;
      let token = (await store.get('token', '')) as string;
      let password = (await store.get('password', '')) as string;

      if (host.length > 0 && password.length > 0) {
        // Has saved credentials → default to Sign In mode
        this.isSignUp = false;
        this.savedHost = host;
        this.savedPort = port;
        this.savedToken = token;
        this.savedPassword = password;
        let portNum = parseInt(port) || DEFAULT_PORT;
        this.savedAddress = portNum === DEFAULT_PORT ? host : `${host}:${portNum}`;
      } else {
        // No saved credentials → Sign Up mode
        this.isSignUp = true;
        if (host.length > 0) {
          let portNum = parseInt(port) || DEFAULT_PORT;
          this.address = portNum === DEFAULT_PORT ? host : `${host}:${portNum}`;
        }
        if (token.length > 0) {
          this.token = token;
        }
      }
    } catch { /* ignore */ }
  }

  private parseAddress(): ParsedAddress | undefined {
    let addr = this.address.trim();
    if (addr.length === 0) return undefined;

    let host: string;
    let port: number = DEFAULT_PORT;

    if (addr.startsWith('[')) {
      let closeBracket = addr.indexOf(']');
      if (closeBracket < 0) {
        host = addr.substring(1);
      } else {
        host = addr.substring(1, closeBracket);
        let afterBracket = addr.substring(closeBracket + 1);
        if (afterBracket.startsWith(':')) {
          let p = parseInt(afterBracket.substring(1));
          if (p > 0 && p <= 65535) port = p;
        }
      }
    } else {
      let lastColon = addr.lastIndexOf(':');
      if (lastColon > 0) {
        let possiblePort = parseInt(addr.substring(lastColon + 1));
        if (possiblePort > 0 && possiblePort <= 65535) {
          host = addr.substring(0, lastColon);
          port = possiblePort;
        } else {
          host = addr;
        }
      } else {
        host = addr;
      }
    }

    let result: ParsedAddress = { host: host, port: port };
    return result;
  }

  // ---- Sign Up: token + set password ----

  private doSignUp(): void {
    this.errorMsg = '';

    let parsed = this.parseAddress();
    if (!parsed) {
      this.errorMsg = I18n.t('login.error.emptyAddress');
      return;
    }

    let tkn = this.token.trim();
    if (tkn.length === 0) {
      this.errorMsg = I18n.t('login.error.emptyToken');
      return;
    }

    let pwd = this.newPassword;
    if (pwd.length === 0) {
      this.errorMsg = I18n.t('login.error.emptyPassword');
      return;
    }

    if (pwd !== this.confirmPassword) {
      this.errorMsg = I18n.t('login.error.passwordMismatch');
      return;
    }

    this.isConnecting = true;
    this.connectResolved = false;

    let endpoint: GatewayEndpoint = {
      host: parsed.host,
      port: parsed.port,
      useTls: false,
    };

    let ctx = getContext(this) as common.UIAbilityContext;
    let runtime = NodeRuntime.getInstance();

    this.stateListener = (state: ConnectionState, text: string) => {
      if (this.connectResolved) return;
      LogService.getInstance().info(TAG, `SignUp state: ${state} - ${text}`);

      if (state === ConnectionState.Connected) {
        this.connectResolved = true;
        this.onSignUpSuccess(ctx, parsed!.host, parsed!.port, tkn, pwd);
      } else if (state === ConnectionState.Error) {
        this.connectResolved = true;
        this.onConnectFailed(text);
      }
    };
    runtime.addStateListener(this.stateListener);

    this.timeoutId = setTimeout(() => {
      this.timeoutId = -1;
      if (!this.connectResolved) {
        this.connectResolved = true;
        runtime.disconnect();
        this.cleanupListener();
        this.isConnecting = false;
        this.errorMsg = I18n.t('login.error.timeout');
      }
    }, LOGIN_TIMEOUT_MS);

    // Load display name and connect with token auth
    runtime.loadDisplayName(ctx).then(() => {
      runtime.connect(ctx, endpoint, tkn, undefined);
    });
  }

  private async onSignUpSuccess(ctx: common.UIAbilityContext, host: string, port: number, token: string, password: string): Promise<void> {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
    this.cleanupListener();

    LogService.getInstance().info(TAG, 'Sign up success, saving credentials');

    try {
      let gwStore = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await gwStore.put('enabled', true);
      await gwStore.put('host', host);
      await gwStore.put('port', port.toString());
      await gwStore.put('useTls', false);
      await gwStore.put('token', token);
      await gwStore.put('password', password);
      await gwStore.flush();

      let loginStore = await preferences.getPreferences(ctx, Constants.PREFS_LOGIN);
      await loginStore.put('loggedIn', true);
      await loginStore.flush();
    } catch (e) {
      LogService.getInstance().warn(TAG, `Failed to save credentials: ${(e as Error).message ?? ''}`);
    }

    router.replaceUrl({ url: 'pages/Index' });
  }

  // ---- Sign In: password only ----

  private doSignIn(): void {
    this.errorMsg = '';

    let pwd = this.password.trim();
    if (pwd.length === 0) {
      this.errorMsg = I18n.t('login.error.emptyPassword');
      return;
    }

    // Verify password against saved password locally
    if (pwd !== this.savedPassword) {
      this.errorMsg = I18n.t('login.error.wrongPassword');
      return;
    }

    // Password matches, connect with saved credentials
    this.isConnecting = true;
    this.connectResolved = false;

    let host = this.savedHost;
    let port = parseInt(this.savedPort) || DEFAULT_PORT;
    let endpoint: GatewayEndpoint = {
      host: host,
      port: port,
      useTls: false,
    };

    let ctx = getContext(this) as common.UIAbilityContext;
    let runtime = NodeRuntime.getInstance();
    let tkn = this.savedToken;

    this.stateListener = (state: ConnectionState, text: string) => {
      if (this.connectResolved) return;
      LogService.getInstance().info(TAG, `SignIn state: ${state} - ${text}`);

      if (state === ConnectionState.Connected) {
        this.connectResolved = true;
        this.onSignInSuccess(ctx);
      } else if (state === ConnectionState.Error) {
        this.connectResolved = true;
        this.onConnectFailed(text);
      }
    };
    runtime.addStateListener(this.stateListener);

    this.timeoutId = setTimeout(() => {
      this.timeoutId = -1;
      if (!this.connectResolved) {
        this.connectResolved = true;
        runtime.disconnect();
        this.cleanupListener();
        this.isConnecting = false;
        this.errorMsg = I18n.t('login.error.timeout');
      }
    }, LOGIN_TIMEOUT_MS);

    runtime.loadDisplayName(ctx).then(() => {
      runtime.connect(ctx, endpoint,
        tkn.length > 0 ? tkn : undefined,
        pwd);
    });
  }

  private async onSignInSuccess(ctx: common.UIAbilityContext): Promise<void> {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
    this.cleanupListener();

    LogService.getInstance().info(TAG, 'Sign in success');

    try {
      let loginStore = await preferences.getPreferences(ctx, Constants.PREFS_LOGIN);
      await loginStore.put('loggedIn', true);
      await loginStore.flush();
    } catch (e) {
      LogService.getInstance().warn(TAG, `Failed to save login state: ${(e as Error).message ?? ''}`);
    }

    router.replaceUrl({ url: 'pages/Index' });
  }

  // ---- Common ----

  private onConnectFailed(text: string): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
    this.cleanupListener();

    NodeRuntime.getInstance().disconnect();
    this.isConnecting = false;

    let lowerText = text.toLowerCase();
    if (lowerText.includes('auth') || lowerText.includes('unauthorized') || lowerText.includes('forbidden') || lowerText.includes('password')) {
      this.errorMsg = I18n.t('login.error.authFailed');
    } else if (lowerText.includes('connect') || lowerText.includes('refused') || lowerText.includes('dns') || lowerText.includes('host')) {
      this.errorMsg = I18n.t('login.error.connectionFailed');
    } else {
      this.errorMsg = I18n.t('login.error.connectionFailed') + ': ' + text;
    }
  }

  private cleanupListener(): void {
    if (this.stateListener) {
      NodeRuntime.getInstance().removeStateListener(this.stateListener);
      this.stateListener = undefined;
    }
  }
}
