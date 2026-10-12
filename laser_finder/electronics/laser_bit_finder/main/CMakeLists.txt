idf_component_register(SRCS "main.c"
        REQUIRES  esp_driver_ledc  
                  esp_driver_i2c
                  esp_lcd
                    PRIV_REQUIRES esp_adc
                    INCLUDE_DIRS ".")
