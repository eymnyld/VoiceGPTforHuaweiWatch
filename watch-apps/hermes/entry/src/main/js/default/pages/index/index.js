import router from '@system.router';

// Splash page: the phone connection is started later, on the real page, once the app is up
export default {
    data: {},
    onShow() {
        setTimeout(function () {
            router.replace({ uri: 'pages/main/main' });
        }, 400);
    }
};
