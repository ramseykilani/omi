# Questions for you

Short answers are fine. "Don't know" is a useful answer too.

## Setup
1. **Sign-in:** does the fork APK let you sign in (browser page → back to the app)? If not, the exact error text or a screenshot.
   This is the one thing I couldn't test, and it decides whether the APK is a daily driver or only a diagnostics tool.
2. Phone make/model and Android version? Any battery-saver or "app sleeping" features on (Samsung, Xiaomi, OnePlus, etc.)?
3. Official Omi app version (Settings → About) when the problems happened?
4. Was **Background mode** (Settings → Recording & Transcription) on in the official app? Do you usually swipe the app away?
5. Do you use **Transcribe Later / offline (batch) mode**, or live transcription?

## Charging
6. What powers the dock: wall adapter (brand/rating), laptop, power bank? Do you have another 5 V USB charger to test with?
7. When you say you "can't tell if it's charging": is the LED **dark**, **solid**, or **blinking** on the dock? Which colours?
8. Have you ever seen it **solid green**?
9. Does it charge if you hold it pressed onto the dock, versus just resting it on there?

## Battery and shutdowns
10. Roughly how long does it last from a full charge, and has that changed since you got it? How old is the device?
11. When it "turns off": was it on your body, on the dock, or sitting on a desk? What % did the app show just before?
12. After it turns off, does a **single button press** bring it back immediately, or does it need charging first?
13. Have you noticed it **buzzing by itself** (repeated short vibrations)?
14. Any chance the button gets held (clip pressure, lying on it)? A 3 s hold powers it off.

## Connection and OTA
15. When the connection drops: is the device near the phone, and is the phone screen off, the app in the background, or the app swiped away?
16. After a drop, does it come back on its own, or only after you open the app / toggle Bluetooth / restart something?
17. For the failed firmware updates: which versions (from → to), what did the app say, and did the version shown afterwards change?
18. Have you ever had to "Forget" the Omi in Android Bluetooth settings to get it to reconnect?

## Decisions for later (no rush)
19. Would you be willing to flash the **fork firmware** over the air once its CI build is green and you've reviewed it?
    It goes through the app's Developer Settings → local firmware. It's the only way to get the reset-cause/battery-mV diagnostics
    and the shutdown fixes. The fallback if it goes wrong is a J-Link (~$20 clone, or a Nordic DK), which you may not have.
20. Is it OK to turn **Background mode on by default** in the fork, so a fresh install keeps the link after the app is swiped away?
