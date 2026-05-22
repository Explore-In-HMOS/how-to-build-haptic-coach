import { common } from '@kit.AbilityKit';
import { ArcButton, ArcButtonOptions, ArcButtonPosition, ArcButtonStatus, ArcButtonStyleMode, ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { CoachAudioStatus, createDefaultCoachStatus, RhythmCoachAudioService } from '../services/RhythmCoachAudioService';

const CADENCE_SPM = 160;
const BEAT_INTERVAL_MS = 375;

@Entry
@Component
struct Index {
  @State status: CoachAudioStatus = createDefaultCoachStatus();
  @State isRunning: boolean = false;
  @State beatCount: number = 0;
  @State isBusy: boolean = false;
  @State lastError: string = '';

  private audioService?: RhythmCoachAudioService;
  private beatTimer: number = -1;
  private refreshSequence: number = 0;
  private isDisposed: boolean = false;

  /**
   * Initializes the audio service and subscribes the page to output-device and playback changes.
   */
  aboutToAppear(): void {
    this.isDisposed = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.audioService = new RhythmCoachAudioService(context);
    this.audioService.subscribeToChanges(() => {
      this.refreshStatus();
    }, () => {
      this.handleCoachEnded();
    });
    this.refreshStatus();
  }

  /**
   * Releases playback resources when the page leaves the screen.
   */
  aboutToDisappear(): void {
    this.isDisposed = true;
    this.stopBeatTimer();
    if (this.audioService !== undefined) {
      this.audioService.unsubscribeFromChanges();
      this.audioService.stopCoach()
        .catch((err: Error) => {
          this.lastError = err.message;
        });
    }
  }

  /**
   * Builds the fixed watch-face layout with centered coach details and a bottom-edge action button.
   */
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 3 }) {
        this.Header()

        if (this.isRunning) {
          this.ActivePanel()
        } else {
          this.SetupPanel()
        }
      }
      .width('82%')
      .height('66%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .offset({ y: -14 })

      if (this.isRunning) {
        this.ActionArcButton(this.getStopLabel(), false, () => {
          this.stopCoach();
        })
      } else {
        this.ActionArcButton(this.getStartLabel(), true, () => {
          this.startCoach();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.coach_background'))
  }

  /**
   * Renders the compact title at the top of the centered content group.
   */
  @Builder
  private Header() {
    Column() {
      Text($r('app.string.coach_title'))
        .fontColor($r('app.color.coach_text_primary'))
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .width('100%')
  }

  /**
   * Renders the idle state with cadence, output routing, and setup diagnostics.
   */
  @Builder
  private SetupPanel() {
    Column({ space: 2 }) {
      this.TempoPanel(`${CADENCE_SPM}`, $r('app.string.coach_unit_spm'), $r('app.string.coach_state_ready'))

      Text(this.status.mode)
        .fontSize(8)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.modeColor())
        .textAlign(TextAlign.Center)
        .maxLines(1)

      this.StatusRow($r('app.string.coach_label_output'), this.status.preferredDeviceName)
      this.StatusRow($r('app.string.coach_label_spatial'), this.getSpatialText())
      this.StatusRow($r('app.string.coach_label_streams'), `${this.status.activeRendererCount}`)

      if (this.lastError.length > 0) {
        Text(this.lastError)
          .width('100%')
          .fontSize(8)
          .fontColor($r('app.color.coach_error'))
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * Renders the running state with the live beat counter and current cue details.
   */
  @Builder
  private ActivePanel() {
    Column({ space: 2 }) {
      this.TempoPanel(`${this.beatCount}`, $r('app.string.coach_unit_beats'), $r('app.string.coach_state_live'))

      Text($r('app.string.coach_active_title'))
        .fontColor($r('app.color.coach_text_primary'))
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)
        .maxLines(1)

      this.StatusRow($r('app.string.coach_label_mode'), this.status.mode)
      this.StatusRow($r('app.string.coach_label_cue'), this.status.cueStatus)
      this.StatusRow($r('app.string.coach_label_muted'), `A ${this.status.audioMuted} / H ${this.status.hapticMuted}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * Displays the primary numeric tempo or beat value with a small state marker.
   *
   * @param value Main value to show in the panel.
   * @param unit Unit label displayed below the value.
   * @param state State label displayed above the value.
   */
  @Builder
  private TempoPanel(value: string, unit: ResourceStr, state: ResourceStr) {
    Column({ space: 1 }) {
      Row() {
        Text(state)
          .fontSize(6)
          .fontColor(this.modeColor())
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Text(value)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.coach_text_primary'))
        .textAlign(TextAlign.Center)
        .maxLines(1)

      Text(unit)
        .fontSize(7)
        .fontColor($r('app.color.coach_text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(1)

      Row()
        .width(38)
        .height(2)
        .borderRadius(2)
        .backgroundColor(this.modeColor())
    }
    .width('76%')
    .padding({ top: 3, bottom: 4, left: 6, right: 6 })
    .borderRadius(8)
    .backgroundColor($r('app.color.coach_panel_background'))
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * Places the watch-native arc action button on a bottom-aligned overlay.
   *
   * @param label Resource label shown by the ArcButton.
   * @param isPrimary Whether to use the positive action color or stop color.
   * @param action Callback invoked when the enabled ArcButton is clicked.
   */
  @Builder
  private ActionArcButton(label: ResourceStr, isPrimary: boolean, action: () => void) {
    Stack({ alignContent: Alignment.Bottom }) {
      ArcButton({
        options: new ArcButtonOptions({
          label,
          position: ArcButtonPosition.BOTTOM_EDGE,
          styleMode: ArcButtonStyleMode.CUSTOM,
          status: this.isBusy ? ArcButtonStatus.DISABLED : ArcButtonStatus.NORMAL,
          backgroundColor: isPrimary ?
          ColorMetrics.resourceColor($r('app.color.coach_primary')) :
          ColorMetrics.resourceColor($r('app.color.coach_stop')),
          shadowColor: ColorMetrics.resourceColor($r('app.color.coach_shadow')),
          shadowEnabled: true,
          fontSize: LengthMetrics.fp(12),
          fontColor: isPrimary ?
          ColorMetrics.resourceColor($r('app.color.coach_text_dark')) :
          ColorMetrics.resourceColor($r('app.color.coach_text_primary')),
          pressedFontColor: ColorMetrics.resourceColor($r('app.color.coach_text_pressed')),
          fontMargin: {
            start: LengthMetrics.vp(18),
            top: LengthMetrics.vp(4),
            end: LengthMetrics.vp(18),
            bottom: LengthMetrics.vp(6)
          },
          onClick: () => {
            if (!this.isBusy) {
              action();
            }
          }
        })
      })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Shows a compact one-line key/value detail row.
   *
   * @param label Resource label for the row.
   * @param value Current value displayed on the right.
   */
  @Builder
  private StatusRow(label: ResourceStr, value: string | ResourceStr) {
    Row() {
      Text(label)
        .fontSize(6)
        .fontColor($r('app.color.coach_text_secondary'))
        .maxLines(1)
        .textAlign(TextAlign.Start)
        .width('32%')

      Text(value)
        .fontSize(8)
        .fontColor($r('app.color.coach_text_primary'))
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .width('68%')
    }
    .width('92%')
    .height(16)
    .padding({ left: 6, right: 6 })
    .borderRadius(8)
    .backgroundColor($r('app.color.coach_status_row_background'))
    .alignItems(VerticalAlign.Center)
  }

  /**
   * Refreshes output routing, spatial support, and playback state from the audio service.
   */
  private refreshStatus(): void {
    if (this.audioService === undefined) {
      return;
    }
    const sequence = ++this.refreshSequence;
    this.audioService.getCoachAudioStatus()
      .then((status: CoachAudioStatus) => {
        if (this.isDisposed || sequence !== this.refreshSequence) {
          return;
        }
        this.status = status;
      })
      .catch((err: Error) => {
        if (this.isDisposed || sequence !== this.refreshSequence) {
          return;
        }
        this.lastError = err.message;
      });
  }

  /**
   * Starts the cadence coach and begins the local beat counter after playback starts.
   */
  private startCoach(): void {
    if (this.audioService === undefined || this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.lastError = '';
    this.audioService.startCoach(this.status.mode)
      .then(() => {
        this.isRunning = true;
        this.startBeatTimer();
        this.refreshStatus();
      })
      .catch((err: Error) => {
        this.lastError = err.message;
        this.refreshStatus();
      })
      .finally(() => {
        this.isBusy = false;
      });
  }

  /**
   * Stops the cadence coach and clears the local beat counter timer.
   */
  private stopCoach(): void {
    if (this.audioService === undefined || this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.audioService.stopCoach()
      .then(() => {
        this.isRunning = false;
        this.stopBeatTimer();
        this.refreshStatus();
      })
      .catch((err: Error) => {
        this.lastError = err.message;
      })
      .finally(() => {
        this.isBusy = false;
      });
  }

  /**
   * Starts the display-only beat counter at the same cadence interval as the cue asset.
   */
  private startBeatTimer(): void {
    this.stopBeatTimer();
    this.beatCount = 0;
    this.beatTimer = setInterval(() => {
      this.beatCount += 1;
    }, BEAT_INTERVAL_MS);
  }

  /**
   * Clears the beat counter timer if it is currently active.
   */
  private stopBeatTimer(): void {
    if (this.beatTimer >= 0) {
      clearInterval(this.beatTimer);
      this.beatTimer = -1;
    }
  }

  /**
   * Maps the spatial audio status flags to a localized display label.
   *
   * @returns Resource label describing spatial audio availability.
   */
  private getSpatialText(): ResourceStr {
    if (!this.status.spatialSupported) {
      return $r('app.string.coach_spatial_unavailable');
    }
    return this.status.spatialEnabled ? $r('app.string.coach_spatial_enabled') : $r('app.string.coach_spatial_supported');
  }

  /**
   * Chooses the semantic color for the current coach mode.
   *
   * @returns Resource color for normal, warning, or error status.
   */
  private modeColor(): ResourceColor {
    if (this.status.mode === 'Setup Error') {
      return $r('app.color.coach_error');
    }
    if (this.status.mode === 'Haptic-Only Fallback') {
      return $r('app.color.coach_warning');
    }
    return $r('app.color.coach_primary');
  }

  /**
   * Returns the localized start button label for the current busy state.
   *
   * @returns Start or starting label resource.
   */
  private getStartLabel(): ResourceStr {
    return this.isBusy ? $r('app.string.coach_action_starting') : $r('app.string.coach_action_start');
  }

  /**
   * Returns the localized stop button label for the current busy state.
   *
   * @returns Stop or stopping label resource.
   */
  private getStopLabel(): ResourceStr {
    return this.isBusy ? $r('app.string.coach_action_stopping') : $r('app.string.coach_action_stop');
  }

  /**
   * Synchronizes UI state when the audio-haptic cue ends by itself.
   */
  private handleCoachEnded(): void {
    this.isRunning = false;
    this.stopBeatTimer();
    this.refreshStatus();
  }
}
