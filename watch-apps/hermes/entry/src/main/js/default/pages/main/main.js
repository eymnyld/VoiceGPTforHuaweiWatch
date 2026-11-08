import bridge from '../../common/bridge.js';

export default {
    data: {
        reply: 'Connecting…',
        defaultLabel: 'Voice chat',
        language: 'en',
        ready: false,
        waiting: false,
        favoriteHermes: false,
        favoriteCodex: false,
        favoriteClaude: false,
        hasVoiceFavorites: false
    },
    onInit() {
        var page = this;
        this.active = true;
        bridge.listen(function (message) {
            if (message.t === 'voice-favorites' && typeof message.s === 'string') {
                page.language = message.lang === 'tr' ? 'tr' : 'en';
                page.defaultLabel = page.localized('Voice chat', 'Sesli sohbet');
                if (!page.waiting && !page.hasResponse) {
                    page.reply = page.localized('Choose a voice provider.', 'Bir ses sağlayıcısı seç.');
                }
                var favorites = message.s.split(',');
                page.favoriteHermes = favorites.indexOf('hermes') !== -1;
                page.favoriteCodex = favorites.indexOf('codex') !== -1;
                page.favoriteClaude = favorites.indexOf('claude') !== -1;
                page.hasVoiceFavorites = page.favoriteHermes || page.favoriteCodex || page.favoriteClaude;
            }
            if (message.t === 'hermes-reply' && typeof message.s === 'string') {
                clearTimeout(page.replyTimer);
                page.waiting = false;
                page.hasResponse = true;
                page.reply = message.s;
            }
        });
        bridge.start(function (problem) {
            if (!page.active) {
                return;
            }
            page.ready = !problem;
            page.reply = problem ? page.localized('Connection: ', 'Bağlantı: ') + problem : page.localized('Choose a voice provider.', 'Bir ses sağlayıcısı seç.');
            if (!problem) { bridge.send({ t: 'voice-favorites' }, function () {}); }
        });
    },
    onDestroy() {
        this.active = false;
        clearTimeout(this.replyTimer);
        this.waiting = false;
        bridge.listen(null);
    },
    localized(english, turkish) {
        return this.language === 'tr' ? turkish : english;
    },
    startDefault() {
        this.requestReply('hermes-dictate');
    },
    startProvider(provider) {
        this.requestReply('voice-start', provider);
    },
    requestReply(type, provider) {
        if (!this.ready || this.waiting) {
            return;
        }

        var page = this;
        this.waiting = true;
        this.reply = this.localized('Waiting for iPhone…', 'iPhone’dan yanıt bekleniyor…');
        this.replyTimer = setTimeout(function () {
            page.waiting = false;
            page.reply = page.localized('No reply. Open HuaSideload and try again.', 'Yanıt gelmedi. HuaSideload’u açıp tekrar dene.');
        }, 8000);
        var timer = this.replyTimer;
        var message = { t: type };
        if (provider) { message.s = provider; }
        bridge.send(message, function (ok) {
            if (!ok && page.waiting && page.replyTimer === timer) {
                clearTimeout(timer);
                page.waiting = false;
                page.reply = page.localized('Could not send the request.', 'Mesaj gönderilemedi.');
            }
        });
    }
};
