module leizd::initializer {

    use leizd::repository;
    use leizd::pool;

    public entry fun initialize(owner: &signer) {
        repository::initialize(owner);
    }

    public entry fun initialize_coin<C>(owner: &signer) {
        pool::init_pool<C>(owner);
    }
}