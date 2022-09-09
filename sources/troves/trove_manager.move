module leizd::trove_manager {
    use std::signer;
    use leizd::sorted_trove;
    use leizd::trove;
    use leizd::permission;

    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        trove::initialize(owner)
    }

    public entry fun initialize_token<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        sorted_trove::initialize<C>(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64)  {
        trove::open_trove<C>(account, amount);
        sorted_trove::insert<C>(signer::address_of(account))
    }


    public entry fun redeem<C>(account: &signer, amount: u64) {
        let redeemed = 0;
        while (redeemed < amount) {
            let target_address = sorted_trove::head<C>();
            let trove_amount = trove::trove_amount<C>(target_address);
            if (amount < redeemed + trove_amount) {
                redeem_trove<C>(account, target_address, amount - redeemed);
                break
            } else {
                redeem_and_remove_trove<C>(account, target_address, trove_amount);
                redeemed = redeemed + trove_amount;
            };
        }
    }

    fun redeem_and_remove_trove<C>(account: &signer, target_address: address, amount: u64) {
        redeem_trove<C>(account, target_address, amount);
        remove_trove<C>(signer::address_of(account))
    }

    fun redeem_trove<C>(account: &signer, target_address: address, amount: u64) {
        trove::redeem<C>(account, target_address, amount)
    }

    fun remove_trove<C>(account: address) {
        sorted_trove::remove<C>(account)
    }

    public entry fun close_trove<C>(account: &signer) {
        trove::close_trove<C>(account)
    }

    public entry fun repay<C>(account: &signer, collateral_amount: u64) {
        trove::repay<C>(account, collateral_amount);
    }

}