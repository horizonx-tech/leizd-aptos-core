module leizd::system_administrator {

    use leizd::pool;
    use leizd::system_status;

    public entry fun pause_pool<C>() {
        pool::update_status<C>(false);
    }

    public entry fun resume_pool<C>() {
        pool::update_status<C>(true);
    }

    public entry fun pause_protocol() {
        system_status::update_status(false);
    }

    public entry fun resume_protocol() {
        system_status::update_status(true);
    }
}