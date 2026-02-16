import { common } from '@kit.AbilityKit';
import { LocalTokenizer } from './LocalTokenizer';
import { LocalTransformer } from './LocalTransformer';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';

export class LocalEmbedding {
  private static instance: LocalEmbedding | undefined = undefined;
  private tokenizer: LocalTokenizer | undefined = undefined;
  private transformer: LocalTransformer | undefined = undefined;
  private loaded: boolean = false;
  private loading: boolean = false;
  private loadPromise: Promise<boolean> | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'LocalEmbedding';

  static getInstance(): LocalEmbedding {
    if (!LocalEmbedding.instance) {
      LocalEmbedding.instance = new LocalEmbedding();
    }
    return LocalEmbedding.instance;
  }

  /**
   * Start preloading the model in background.
   * Call this early (e.g., in EntryAbility.onWindowStageCreate) to avoid
   * blocking the UI when the user first sends a message.
   */
  preload(context: common.Context): void {
    if (this.loaded || this.loading) return;
    this.log.info(this.TAG, 'Starting background preload...');
    // Use setTimeout to yield to the event loop, avoiding UI freeze
    setTimeout((): void => {
      this.init(context).catch((): void => {});
    }, 100);
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.loaded) return true;
    // If already loading, wait for the existing promise
    if (this.loading && this.loadPromise) {
      return this.loadPromise;
    }
    this.loading = true;
    this.loadPromise = this.doLoad(context);
    return this.loadPromise;
  }

  private async doLoad(context: common.Context): Promise<boolean> {
    try {
      let t0 = Date.now();
      this.log.info(this.TAG, 'Loading tokenizer...');
      this.tokenizer = new LocalTokenizer();
      await this.tokenizer.load(context);
      // Yield to event loop between heavy operations
      await this.yieldToEventLoop();
      this.log.info(this.TAG, 'Loading transformer...');
      this.transformer = new LocalTransformer();
      await this.transformer.load(context);
      this.loaded = true;
      this.log.info(this.TAG, 'Local embedding model loaded in ' + (Date.now() - t0).toString() + 'ms');
      return true;
    } catch (e) {
      this.log.warn(this.TAG, 'Failed to load model: ' + ((e as Error).message ?? String(e)));
      this.loaded = false;
      return false;
    } finally {
      this.loading = false;
      this.loadPromise = undefined;
    }
  }

  private yieldToEventLoop(): Promise<void> {
    return new Promise<void>((resolve): void => {
      setTimeout((): void => resolve(), 0);
    });
  }

  isReady(): boolean {
    return this.loaded;
  }

  async embed(text: string): Promise<number[]> {
    if (!this.loaded || !this.tokenizer || !this.transformer) return [];
    try {
      let t0 = Date.now();
      let encoded = this.tokenizer.encode(text);
      // Use async forward with yields to prevent UI blocking
      let vec = await this.transformer.forwardAsync(encoded.inputIds, encoded.attentionMask, encoded.tokenTypeIds);
      let elapsed = Date.now() - t0;
      this.log.info(this.TAG, 'embed: ' + elapsed.toString() + 'ms, dim=' + vec.length.toString() + ', text="' + text.substring(0, 40) + '"');
      return Array.from(vec);
    } catch (e) {
      this.log.warn(this.TAG, 'embed failed: ' + ((e as Error).message ?? String(e)));
      return [];
    }
  }

  getDimension(): number {
    return Constants.LOCAL_EMBEDDING_DIM;
  }

  getModelName(): string {
    return Constants.LOCAL_EMBEDDING_MODEL;
  }
}
