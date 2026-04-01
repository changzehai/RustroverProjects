#![no_main]
#![no_std]

use cortex_m_rt::entry;
use panic_halt as _;
use stm32f4::stm32f407 as pac;
use stm32f4xx_hal::{
    prelude::*,
    rcc::Config,
};

#[entry]
fn main() -> ! {
    let dp = take_device_peripherals();
    let cp = take_core_peripherals();

    let mut rcc = freeze_rcc(dp.RCC);
    let mut delay = make_delay(cp.SYST, &rcc.clocks);

    let gpioe = dp.GPIOE.split(&mut rcc);
    let mut led1 = gpioe.pe8.into_push_pull_output();
    let mut led2 = gpioe.pe9.into_push_pull_output();
    let mut led3 = gpioe.pe10.into_push_pull_output();
    let mut led4 = gpioe.pe11.into_push_pull_output();

    loop {
        led1.set_high();
        delay.delay_ms(500);
        led1.set_low();

        led2.set_high();
        delay.delay_ms(500);
        led2.set_low();

        led3.set_high();
        delay.delay_ms(500);
        led3.set_low();

        led4.set_high();
        delay.delay_ms(500);
        led4.set_low();
    }
}

#[inline(never)]
fn take_device_peripherals() -> pac::Peripherals {
    pac::Peripherals::take().unwrap()
}

#[inline(never)]
fn take_core_peripherals() -> cortex_m::Peripherals {
    cortex_m::Peripherals::take().unwrap()
}

#[inline(never)]
fn freeze_rcc(rcc: pac::RCC) -> stm32f4xx_hal::rcc::Rcc {
    rcc.freeze(Config::hsi().sysclk(84.MHz()))
}

#[inline(never)]
fn make_delay(
    syst: cortex_m::peripheral::SYST,
    clocks: &stm32f4xx_hal::rcc::Clocks,
) -> stm32f4xx_hal::timer::delay::SysDelay {
    syst.delay(clocks)
}
