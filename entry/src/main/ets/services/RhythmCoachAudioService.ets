import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio, audioHaptic } from '@kit.AudioKit';

export type CoachMode =
  'Speaker Coach' |
  'Earbuds Coach' |
  'Immersive Earbuds Coach' |
  'Haptic-Only Fallback' |
  'Setup Error';

export interface CoachAudioStatus {
  outputDeviceCount: number;
  preferredDeviceName: string;
  preferredDeviceType: string;
  activeRendererCount: number;
  spatialSupported: boolean;
  spatialEnabled: boolean;
  audioMuted: boolean;
  hapticMuted: boolean;
  mode: CoachMode;
  cueStatus: string;
}

const AUDIO_RAWFILE = 'cadence_beat.wav';
const HAPTIC_RAWFILE = 'cadence_beat.json';

export function createDefaultCoachStatus(): CoachAudioStatus {
  return {
    outputDeviceCount: 0,
    preferredDeviceName: 'Checking output',
    preferredDeviceType: 'unknown',
    activeRendererCount: 0,
    spatialSupported: false,
    spatialEnabled: false,
    audioMuted: false,
    hapticMuted: false,
    mode: 'Haptic-Only Fallback',
    cueStatus: 'Ready'
  };
}

export class RhythmCoachAudioService {
  private context: common.UIAbilityContext;
  private audioManager = audio.getAudioManager();
  private routingManager = this.audioManager.getRoutingManager();
  private streamManager = this.audioManager.getStreamManager();
  private spatializationManager?: audio.AudioSpatializationManager;
  private audioHapticManager = audioHaptic.getAudioHapticManager();
  private sourceId: number = -1;
  private player?: audioHaptic.AudioHapticPlayer;
  private isActive: boolean = false;
  private cueStatus: string = 'Ready';
  private coachEndedCallback?: () => void;

  private audioPath: string = AUDIO_RAWFILE;
  private hapticPath: string = HAPTIC_RAWFILE;
  private deviceChangeCallback?: (deviceChanged: audio.DeviceChangeAction) => void;
  private rendererChangeCallback?: (rendererInfoArray: audio.AudioRendererChangeInfoArray) => void;
  private preferDeviceChangeCallback?: (devices: audio.AudioDeviceDescriptors) => void;
  private spatialChangeCallback?: (enabled: boolean) => void;

  private rendererInfo: audio.AudioRendererInfo = {
    usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    rendererFlags: 0
  };

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async getCoachAudioStatus(): Promise<CoachAudioStatus> {
    let outputDevices: audio.AudioDeviceDescriptors = [];
    let preferredDevices: audio.AudioDeviceDescriptors = [];
    let rendererStreams: audio.AudioRendererChangeInfoArray = [];
    let spatialSupported = false;
    let spatialEnabled = false;
    let mode: CoachMode = 'Haptic-Only Fallback';

    try {
      outputDevices = await this.routingManager.getDevices(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
    } catch (err) {
      this.logBusinessError('Failed to query output devices', err);
    }

    try {
      preferredDevices = await this.routingManager.getPreferOutputDeviceForRendererInfo(this.rendererInfo);
    } catch (err) {
      this.logBusinessError('Failed to query preferred output', err);
    }

    try {
      rendererStreams = await this.streamManager.getCurrentAudioRendererInfoArray();
    } catch (err) {
      this.logBusinessError('Failed to query renderer streams', err);
    }

    const spatialManager = this.getSpatializationManagerSafe();
    if (spatialManager !== undefined) {
      try {
        spatialSupported = true;
        spatialEnabled = spatialManager.isSpatializationEnabledForCurrentDevice();
      } catch (err) {
        this.logBusinessError('Failed to query spatialization state', err);
      }
    }

    const preferredDevice = preferredDevices.length > 0 ? preferredDevices[0] : undefined;
    const preferredDeviceType = this.getDeviceTypeLabel(preferredDevice);
    const preferredDeviceName = preferredDevice === undefined ?
      'No preferred output' :
      (preferredDevice.displayName || preferredDevice.name || preferredDeviceType);

    if (preferredDevice !== undefined && preferredDevice.deviceType === audio.DeviceType.BLUETOOTH_A2DP) {
      mode = spatialEnabled ? 'Immersive Earbuds Coach' : 'Earbuds Coach';
    } else if (preferredDevice !== undefined && preferredDevice.deviceType === audio.DeviceType.SPEAKER) {
      mode = 'Speaker Coach';
    }

    if (this.cueStatus === 'Setup Error') {
      mode = 'Setup Error';
    }

    return {
      outputDeviceCount: outputDevices.length,
      preferredDeviceName,
      preferredDeviceType,
      activeRendererCount: rendererStreams.length,
      spatialSupported,
      spatialEnabled,
      audioMuted: this.isPlayerMuted(audioHaptic.AudioHapticType.AUDIO_HAPTIC_TYPE_AUDIO),
      hapticMuted: this.isPlayerMuted(audioHaptic.AudioHapticType.AUDIO_HAPTIC_TYPE_HAPTIC),
      mode,
      cueStatus: this.cueStatus
    };
  }

  async startCoach(mode: CoachMode): Promise<void> {
    await this.stopCoach(true);
    this.cueStatus = 'Ready';
    const hapticOnly = mode === 'Haptic-Only Fallback';

    try {
      this.sourceId = await this.registerCoachSource();
      this.configureCoachSource();
      const startedHapticOnly = await this.createAndStartPlayer(hapticOnly);
      this.isActive = true;
      this.cueStatus = startedHapticOnly ? 'haptic only' : 'audio + haptic';
    } catch (err) {
      this.cueStatus = 'Setup Error';
      this.logBusinessError('Failed to start coach', err);
      await this.stopCoach(false);
      throw new Error(this.getErrorMessage(err));
    }
  }

  async stopCoach(resetStatus: boolean = true): Promise<void> {
    try {
      if (this.player !== undefined) {
        await this.player.stop();
        await this.player.release();
        this.player = undefined;
      }

      if (this.sourceId >= 0) {
        await this.audioHapticManager.unregisterSource(this.sourceId);
        this.sourceId = -1;
      }
    } catch (err) {
      this.logBusinessError('Failed to stop coach cleanly', err);
    } finally {
      await this.closeRawFd(this.audioPath);
      await this.closeRawFd(this.hapticPath);
      this.isActive = false;
      if (resetStatus) {
        this.cueStatus = 'Ready';
      }
    }
  }

  subscribeToChanges(onChange: () => void, onCoachEnded?: () => void): void {
    this.unsubscribeFromChanges();
    this.coachEndedCallback = onCoachEnded;
    this.deviceChangeCallback = () => onChange();
    this.rendererChangeCallback = () => onChange();
    this.preferDeviceChangeCallback = () => onChange();
    this.spatialChangeCallback = () => onChange();

    try {
      this.routingManager.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, this.deviceChangeCallback);
    } catch (err) {
      this.deviceChangeCallback = undefined;
      this.logBusinessError('Failed to subscribe for device changes', err);
    }
    try {
      this.routingManager.on('preferOutputDeviceChangeForRendererInfo', this.rendererInfo, this.preferDeviceChangeCallback);
    } catch (err) {
      this.preferDeviceChangeCallback = undefined;
      this.logBusinessError('Failed to subscribe for preferred device changes', err);
    }
    try {
      this.streamManager.on('audioRendererChange', this.rendererChangeCallback);
    } catch (err) {
      this.rendererChangeCallback = undefined;
      this.logBusinessError('Failed to subscribe for renderer changes', err);
    }

    const spatialManager = this.getSpatializationManagerSafe();
    if (spatialManager !== undefined) {
      try {
        spatialManager.on('spatializationEnabledChangeForCurrentDevice', this.spatialChangeCallback);
      } catch (err) {
        this.spatialChangeCallback = undefined;
        this.logBusinessError('Failed to subscribe for spatialization changes', err);
      }
    }
  }

  unsubscribeFromChanges(): void {
    this.coachEndedCallback = undefined;
    if (this.deviceChangeCallback !== undefined) {
      try {
        this.routingManager.off('deviceChange', this.deviceChangeCallback);
      } catch (_) {
      }
      this.deviceChangeCallback = undefined;
    }
    if (this.preferDeviceChangeCallback !== undefined) {
      try {
        this.routingManager.off('preferOutputDeviceChangeForRendererInfo', this.preferDeviceChangeCallback);
      } catch (_) {
      }
      this.preferDeviceChangeCallback = undefined;
    }
    if (this.rendererChangeCallback !== undefined) {
      try {
        this.streamManager.off('audioRendererChange', this.rendererChangeCallback);
      } catch (_) {
      }
      this.rendererChangeCallback = undefined;
    }
    if (this.spatialChangeCallback !== undefined) {
      try {
        this.spatializationManager?.off('spatializationEnabledChangeForCurrentDevice', this.spatialChangeCallback);
      } catch (_) {
      }
      this.spatialChangeCallback = undefined;
    }
  }

  isCoachActive(): boolean {
    return this.isActive;
  }

  private async registerCoachSource(): Promise<number> {
    try {
      const audioFd = await this.context.resourceManager.getRawFd(this.audioPath);
      const hapticFd = await this.context.resourceManager.getRawFd(this.hapticPath);
      try {
        return await this.audioHapticManager.registerSourceFromFd({
          fd: audioFd.fd,
          offset: audioFd.offset,
          length: audioFd.length
        }, {
          fd: hapticFd.fd,
          offset: hapticFd.offset,
          length: hapticFd.length
        });
      } finally {
        await this.closeRawFd(this.audioPath);
        await this.closeRawFd(this.hapticPath);
      }
    } catch (err) {
      this.logBusinessError('FD source registration unavailable, trying rawfile URI registration', err);
      return await this.audioHapticManager.registerSource(this.audioPath, this.hapticPath);
    }
  }

  private configureCoachSource(): void {
    try {
      this.audioHapticManager.setStreamUsage(this.sourceId, audio.StreamUsage.STREAM_USAGE_MUSIC);
    } catch (err) {
      this.logBusinessError('Failed to set stream usage', err);
    }

    try {
      this.audioHapticManager.setAudioLatencyMode(this.sourceId, audioHaptic.AudioLatencyMode.AUDIO_LATENCY_MODE_FAST);
    } catch (err) {
      this.logBusinessError('Failed to set fast audio latency mode', err);
    }
  }

  private async createAndStartPlayer(hapticOnly: boolean): Promise<boolean> {
    this.player = await this.audioHapticManager.createPlayer(this.sourceId, {
      muteAudio: hapticOnly,
      muteHaptics: false
    });
    this.subscribeToPlayerEvents();

    try {
      await this.player.start();
      return hapticOnly;
    } catch (err) {
      if (hapticOnly) {
        throw new Error(this.getErrorMessage(err));
      }

      this.logBusinessError('Audio haptic start failed, retrying haptic-only cue', err);
      await this.releasePlayerOnly();
      this.player = await this.audioHapticManager.createPlayer(this.sourceId, {
        muteAudio: true,
        muteHaptics: false
      });
      this.subscribeToPlayerEvents();
      await this.player.start();
      return true;
    }
  }

  private isPlayerMuted(type: audioHaptic.AudioHapticType): boolean {
    if (this.player === undefined) {
      return false;
    }

    try {
      return this.player.isMuted(type);
    } catch (err) {
      this.logBusinessError('Failed to query player mute state', err);
      return false;
    }
  }

  private subscribeToPlayerEvents(): void {
    try {
      this.player?.on('endOfStream', () => {
        this.isActive = false;
        this.cueStatus = 'Cue ended';
        this.coachEndedCallback?.();
      });
    } catch (err) {
      this.logBusinessError('Failed to subscribe for cue end', err);
    }

    try {
      this.player?.on('audioInterrupt', (interruptEvent: audio.InterruptEvent) => {
        this.handleAudioInterrupt(interruptEvent);
      });
    } catch (err) {
      this.logBusinessError('Failed to subscribe for audio interruption', err);
    }
  }

  private handleAudioInterrupt(interruptEvent: audio.InterruptEvent): void {
    if (interruptEvent.forceType !== audio.InterruptForceType.INTERRUPT_FORCE) {
      return;
    }

    switch (interruptEvent.hintType) {
      case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
      case audio.InterruptHint.INTERRUPT_HINT_STOP:
        this.isActive = false;
        this.cueStatus = 'Interrupted';
        this.coachEndedCallback?.();
        break;
      case audio.InterruptHint.INTERRUPT_HINT_DUCK:
        this.cueStatus = 'Ducked';
        break;
      case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
        this.cueStatus = this.isActive ? 'audio + haptic' : 'Ready';
        break;
      default:
        this.cueStatus = 'Interrupted';
        break;
    }
  }

  private async releasePlayerOnly(): Promise<void> {
    if (this.player === undefined) {
      return;
    }

    try {
      await this.player.stop();
    } catch (_) {
    }
    try {
      await this.player.release();
    } catch (_) {
    }
    this.player = undefined;
  }

  private getDeviceTypeLabel(device?: audio.AudioDeviceDescriptor): string {
    if (device === undefined) {
      return 'unknown';
    }
    switch (device.deviceType) {
      case audio.DeviceType.BLUETOOTH_A2DP:
        return 'Bluetooth earbuds';
      case audio.DeviceType.SPEAKER:
        return 'Watch speaker';
      case audio.DeviceType.WIRED_HEADSET:
      case audio.DeviceType.WIRED_HEADPHONES:
        return 'Wired audio';
      case audio.DeviceType.USB_HEADSET:
      case audio.DeviceType.USB_DEVICE:
        return 'USB audio';
      default:
        return `Device ${device.deviceType}`;
    }
  }

  private async closeRawFd(path: string): Promise<void> {
    try {
      await this.context.resourceManager.closeRawFd(path);
    } catch (_) {
    }
  }

  private getSpatializationManagerSafe(): audio.AudioSpatializationManager | undefined {
    if (this.spatializationManager !== undefined) {
      return this.spatializationManager;
    }

    try {
      this.spatializationManager = this.audioManager.getSpatializationManager();
      return this.spatializationManager;
    } catch (err) {
      this.logBusinessError('Failed to create spatialization manager', err);
      return undefined;
    }
  }

  private logBusinessError(message: string, err: Error | BusinessError | Object): void {
    const errorMessage = this.getErrorMessage(err);
    console.error(`${message}. ${errorMessage}`);
  }

  private getErrorMessage(err: Error | BusinessError | Object): string {
    const error = err as BusinessError;
    if (error.code !== undefined || error.message !== undefined) {
      return `code=${error.code ?? 'unknown'}, message=${error.message ?? 'unknown'}`;
    }
    return JSON.stringify(err);
  }
}
