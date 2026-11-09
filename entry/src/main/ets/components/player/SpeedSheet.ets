/**
 * HPVPlayer - 倍速面板：常用档位 + 自定义滑条。
 */
import { Player } from '@mpv-ohos/mpv-arkts';

const PRESETS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];

@ComponentV2
export struct SpeedSheet {
  @Param @Require player: Player;
  @Local customSpeed: number = 1;

  aboutToAppear(): void {
    this.customSpeed = this.player.state.speed;
  }

  build() {
    Column({ space: 10 }) {
      Text(`当前倍速 ${this.speedLabel(this.player.state.speed)}`)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 12 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(PRESETS, (speed: number) => {
          Text(this.speedLabel(speed))
            .fontSize(15)
            .fontColor(Math.abs(this.player.state.speed - speed) < 0.001 ?
              $r('app.color.brand') : $r('app.color.text_primary'))
            .backgroundColor(Math.abs(this.player.state.speed - speed) < 0.001 ?
              $r('app.color.brand_light') : $r('app.color.input_background'))
            .borderRadius(18)
            .padding({ left: 18, right: 18, top: 8, bottom: 8 })
            .margin(6)
            .onClick(() => {
              this.customSpeed = speed;
              this.player.setSpeed(speed);
            })
        }, (speed: number) => `${speed}`)
      }
      .width('100%')
      .margin({ top: 6 })

      Column({ space: 6 }) {
        Text(`自定义: ${this.speedLabel(this.customSpeed)}`)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Slider({
          value: this.customSpeed,
          min: 0.25,
          max: 4,
          step: 0.05,
        })
          .width('90%')
          .selectedColor($r('app.color.brand'))
          .blockColor($r('app.color.text_on_brand'))
          .trackColor($r('app.color.input_background'))
          .onChange((value: number, mode: SliderChangeMode) => {
            this.customSpeed = parseFloat(value.toFixed(2));
            if (mode === SliderChangeMode.End) {
              this.player.setSpeed(this.customSpeed);
            }
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 10, bottom: 24 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Center)
  }

  private speedLabel(speed: number): string {
    return `${parseFloat(speed.toFixed(2))}x`;
  }
}
