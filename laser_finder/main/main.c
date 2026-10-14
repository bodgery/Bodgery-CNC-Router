/*
 * SPDX-FileCopyrightText: 2022-2023 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "soc/soc_caps.h"
#include "esp_log.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "driver/ledc.h"
#include "driver/i2c_master.h"

#include "esp_lcd_io_i2c.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_sh1107.h"

#include "font_8.h"

static const char* TAG = "laserfinder";


/*---------------------------------------------------------------
        ADC General Macros
---------------------------------------------------------------*/
// ADC1 Channels
#if CONFIG_IDF_TARGET_ESP32
#define ADC1_CHAN4 ADC_CHANNEL_4
#define ADC1_CHAN5 ADC_CHANNEL_5
#else
#define ADC1_CHAN4 ADC_CHANNEL_4
#define ADC1_CHAN5 ADC_CHANNEL_5
#endif

#if (SOC_ADC_PERIPH_NUM >= 2) && !CONFIG_IDF_TARGET_ESP32C3
/**
 * On ESP32C3, ADC2 is no longer supported, due to its HW limitation.
 * Search for errata on espressif website for more details.
 */
#define USE_ADC2 1
#endif

#if USE_ADC2
// ADC2 Channels
#define ADC2_CHAN0 ADC_CHANNEL_0
#endif // #if USE_ADC2

#define ADC_ATTEN ADC_ATTEN_DB_0 // 0-500 mV range for input data

static int adc_raw[2][10];
static int voltage[2][10];
static bool adc_calibration_init(adc_unit_t unit, adc_channel_t channel, adc_atten_t atten, adc_cali_handle_t *out_handle);
static void adc_calibration_deinit(adc_cali_handle_t handle);

/*------------------------------------------------------------
        LEDC General Macros
------------------------------------------------------------*/
typedef struct
{
    int io;
    int channel;
} ledc_io_t;

ledc_io_t left_LED = {
    .io = 21,
    .channel = LEDC_CHANNEL_0};

ledc_io_t center_LED = {
    .io = 22,
    .channel = LEDC_CHANNEL_1};

ledc_io_t right_LED = {
    .io = 23,
    .channel = LEDC_CHANNEL_2};

/*====================================
            I2C
======================================*/

#define SCL_PIN GPIO_NUM_16
#define SDA_PIN GPIO_NUM_17

i2c_master_bus_handle_t bus_handle;
i2c_master_bus_config_t bus_config = {
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .i2c_port = I2C_NUM_0,
    .scl_io_num = SCL_PIN,
    .sda_io_num = SDA_PIN,
    .glitch_ignore_cnt = 7,
    .flags.enable_internal_pullup = true,
};

/*==================================
    SH1107 setup
====================================*/

esp_lcd_panel_io_handle_t display_io_handle = NULL;
esp_lcd_panel_io_i2c_config_t display_io_config = ESP_SH1107_DEFAULT_IO_CONFIG;

esp_lcd_panel_handle_t display_panel_handle = NULL;
esp_lcd_panel_dev_config_t display_panel_config = {
    .bits_per_pixel = 1,
    .reset_gpio_num = -1,
};


uint8_t buffer[128 * 8]; // 128 page pixels * 8 pages, with 8 pixels per page pixel

/*====================================
            LEDC
======================================*/

#define LEDC_TIMER LEDC_TIMER_0
#define LEDC_MODE LEDC_LOW_SPEED_MODE

#define LEDC_DUTY_RES LEDC_TIMER_13_BIT // Set resolution (13-bit: 0 - 8191)
#define LEDC_FREQUENCY 5000             // Frequency in Hz (5 kHz)

esp_err_t update_led_pwm(ledc_channel_t channel, uint32_t value)
{
    esp_err_t ret;
    if ((ret = ledc_set_duty(LEDC_MODE, channel, value)) != ESP_OK)
    {
        return ret;
    }
    return ledc_update_duty(LEDC_MODE, channel);
}

void app_main(void)
{
    //-------------ADC1 Init---------------//
    adc_oneshot_unit_handle_t adc1_handle;
    adc_oneshot_unit_init_cfg_t init_config1 = {
        .unit_id = ADC_UNIT_1,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config1, &adc1_handle));

    //-------------ADC1 Config---------------//
    adc_oneshot_chan_cfg_t config = {
        .atten = ADC_ATTEN,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc1_handle, ADC1_CHAN4, &config)); // left
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc1_handle, ADC1_CHAN5, &config));

    //-------------ADC1 Calibration Init---------------//
    adc_cali_handle_t adc1_cali_chan0_handle = NULL;
    adc_cali_handle_t adc1_cali_chan1_handle = NULL;
    bool do_calibration1_chan0 = adc_calibration_init(ADC_UNIT_1, ADC1_CHAN4, ADC_ATTEN, &adc1_cali_chan0_handle);
    bool do_calibration1_chan1 = adc_calibration_init(ADC_UNIT_1, ADC1_CHAN5, ADC_ATTEN, &adc1_cali_chan1_handle);

#if USE_ADC2
    //-------------ADC2 Init---------------//
    adc_oneshot_unit_handle_t adc2_handle;
    adc_oneshot_unit_init_cfg_t init_config2 = {
        .unit_id = ADC_UNIT_2,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config2, &adc2_handle));

    //-------------ADC2 Calibration Init---------------//
    adc_cali_handle_t adc2_cali_handle = NULL;
    bool do_calibration2 = adc_calibration_init(ADC_UNIT_2, ADC2_CHAN0, ADC_ATTEN, &adc2_cali_handle);

    //-------------ADC2 Config---------------//
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc2_handle, ADC2_CHAN0, &config));
#endif // #if USE_ADC2

    //-------------PWM Setup for LEDS------------//

    // create timer

    ledc_timer_config_t ledc_timer = {
        .speed_mode = LEDC_MODE,
        .timer_num = LEDC_TIMER,
        .duty_resolution = LEDC_DUTY_RES,
        .freq_hz = LEDC_FREQUENCY,
        .clk_cfg = LEDC_AUTO_CLK};
    ledc_timer_config(&ledc_timer);

    // configure the LEDS

    ledc_channel_config_t ledc_channel_left = {
        .speed_mode = LEDC_MODE,
        .channel = left_LED.channel,
        .timer_sel = LEDC_TIMER,
        .gpio_num = left_LED.io,
        .duty = 0, // Set duty to 0%
        .hpoint = 0,
    };

    ledc_channel_config_t ledc_channel_center = {
        .speed_mode = LEDC_MODE,
        .channel = center_LED.channel,
        .timer_sel = LEDC_TIMER,
        .gpio_num = center_LED.io,
        .duty = 0, // Set duty to 0%
        .hpoint = 0,
    };

    ledc_channel_config_t ledc_channel_right = {
        .speed_mode = LEDC_MODE,
        .channel = right_LED.channel,
        .timer_sel = LEDC_TIMER,
        .gpio_num = right_LED.io,
        .duty = 0, // Set duty to 0%
        .hpoint = 0,
    };

    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel_left));
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel_center));
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel_right));

    /*======================================================
                Display
    =======================================================*/

            // initialize the i2c bus

    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &bus_handle));

            // initiailse the lcd display

    ESP_ERROR_CHECK(esp_lcd_new_panel_io_i2c(bus_handle, &display_io_config, &display_io_handle));

            // initialize the panel

    ESP_ERROR_CHECK(esp_lcd_new_panel_sh1107(display_io_handle, &display_panel_config, &display_panel_handle));
    // Initialize the screen (this one isn't optional at all!)
    ESP_ERROR_CHECK(esp_lcd_panel_init(display_panel_handle));

    // Turn on the screen (Easier to see something, right?)
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(display_panel_handle, true));
    
    
    memset(buffer, 0xff, SH1107_HEIGHT*SH1107_WIDTH);
    ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(display_panel_handle, 48, 16, 80, 48, buffer));
    int diff;

    int leds[] = {left_LED.channel,
                  center_LED.channel,
                  right_LED.channel};

    // starting flash (x3)
    for (int i = 0; i < 6; i++)
    {
        for (int j = 0; j < sizeof(leds) / sizeof(leds[0]); j++)
        {
            ESP_ERROR_CHECK(update_led_pwm(leds[j], (uint32_t)(i % 2 == 0) ? 4095 : 0));
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }

    while (1)
    {
        ESP_ERROR_CHECK(adc_oneshot_read(adc1_handle, ADC1_CHAN4, &adc_raw[0][0]));
        ESP_LOGI(TAG, "ADC%d Channel[%d] Raw Data: %d", ADC_UNIT_1 + 1, ADC1_CHAN4, adc_raw[0][0]);
        if (do_calibration1_chan0)
        {
            ESP_ERROR_CHECK(adc_cali_raw_to_voltage(adc1_cali_chan0_handle, adc_raw[0][0], &voltage[0][0]));
            ESP_LOGI(TAG, "ADC%d Channel[%d] Cali Voltage: %d mV", ADC_UNIT_1 + 1, ADC1_CHAN4, voltage[0][0]);
        }
        vTaskDelay(pdMS_TO_TICKS(50));

        // set right led in proportion the the signal

        ESP_ERROR_CHECK(update_led_pwm(right_LED.channel, adc_raw[0][0]));

        ESP_ERROR_CHECK(adc_oneshot_read(adc1_handle, ADC1_CHAN5, &adc_raw[0][1]));
        ESP_LOGI(TAG, "ADC%d Channel[%d] Raw Data: %d", ADC_UNIT_1 + 1, ADC1_CHAN5, adc_raw[0][1]);
        vTaskDelay(pdMS_TO_TICKS(50));
        if (do_calibration1_chan1)
        {
            ESP_ERROR_CHECK(adc_cali_raw_to_voltage(adc1_cali_chan1_handle, adc_raw[0][1], &voltage[0][1]));
            ESP_LOGI(TAG, "ADC%d Channel[%d] Cali Voltage: %d mV", ADC_UNIT_1 + 1, ADC1_CHAN5, voltage[0][1]);
        }
        ESP_ERROR_CHECK(update_led_pwm(left_LED.channel, adc_raw[0][1]));

        diff = abs(adc_raw[0][1] - adc_raw[0][0]);
        ESP_LOGI(TAG, "DELTA = %d", diff);
        ESP_ERROR_CHECK(update_led_pwm(center_LED.channel, diff));
        vTaskDelay(pdMS_TO_TICKS(50));

        // #if USE_ADC2
        //         ESP_ERROR_CHECK(adc_oneshot_read(adc2_handle, ADC2_CHAN0, &adc_raw[1][0]));
        //         ESP_LOGI(TAG, "ADC%d Channel[%d] Raw Data: %d", ADC_UNIT_2 + 1, ADC2_CHAN0, adc_raw[1][0]);
        //         if (do_calibration2)
        //         {
        //             ESP_ERROR_CHECK(adc_cali_raw_to_voltage(adc2_cali_handle, adc_raw[1][0], &voltage[1][0]));
        //             ESP_LOGI(TAG, "ADC%d Channel[%d] Cali Voltage: %d mV", ADC_UNIT_2 + 1, ADC2_CHAN0, voltage[1][0]);
        //         }
        //         vTaskDelay(pdMS_TO_TICKS(1000));
        // #endif // #if USE_ADC2
    }

    // Tear Down
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc1_handle));
    if (do_calibration1_chan0)
    {
        adc_calibration_deinit(adc1_cali_chan0_handle);
    }
    if (do_calibration1_chan1)
    {
        adc_calibration_deinit(adc1_cali_chan1_handle);
    }

#if USE_ADC2
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc2_handle));
    if (do_calibration2)
    {
        adc_calibration_deinit(adc2_cali_handle);
    }
#endif // #if USE_ADC2
}

/*---------------------------------------------------------------
        ADC Calibration
---------------------------------------------------------------*/
static bool adc_calibration_init(adc_unit_t unit, adc_channel_t channel, adc_atten_t atten, adc_cali_handle_t *out_handle)
{
    adc_cali_handle_t handle = NULL;
    esp_err_t ret = ESP_FAIL;
    bool calibrated = false;

#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    if (!calibrated)
    {
        ESP_LOGI(TAG, "calibration scheme version is %s", "Curve Fitting");
        adc_cali_curve_fitting_config_t cali_config = {
            .unit_id = unit,
            .chan = channel,
            .atten = atten,
            .bitwidth = ADC_BITWIDTH_DEFAULT,
        };
        ret = adc_cali_create_scheme_curve_fitting(&cali_config, &handle);
        if (ret == ESP_OK)
        {
            calibrated = true;
        }
    }
#endif

#if ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    if (!calibrated)
    {
        ESP_LOGI(TAG, "calibration scheme version is %s", "Line Fitting");
        adc_cali_line_fitting_config_t cali_config = {
            .unit_id = unit,
            .atten = atten,
            .bitwidth = ADC_BITWIDTH_DEFAULT,
        };
        ret = adc_cali_create_scheme_line_fitting(&cali_config, &handle);
        if (ret == ESP_OK)
        {
            calibrated = true;
        }
    }
#endif

    *out_handle = handle;
    if (ret == ESP_OK)
    {
        ESP_LOGI(TAG, "Calibration Success");
    }
    else if (ret == ESP_ERR_NOT_SUPPORTED || !calibrated)
    {
        ESP_LOGW(TAG, "eFuse not burnt, skip software calibration");
    }
    else
    {
        ESP_LOGE(TAG, "Invalid arg or no memory");
    }

    return calibrated;
}

static void adc_calibration_deinit(adc_cali_handle_t handle)
{
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    ESP_LOGI(TAG, "deregister %s calibration scheme", "Curve Fitting");
    ESP_ERROR_CHECK(adc_cali_delete_scheme_curve_fitting(handle));

#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    ESP_LOGI(TAG, "deregister %s calibration scheme", "Line Fitting");
    ESP_ERROR_CHECK(adc_cali_delete_scheme_line_fitting(handle));
#endif
}
