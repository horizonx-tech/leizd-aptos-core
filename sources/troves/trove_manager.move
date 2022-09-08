module leizd::trove_manager {
    use std::signer;
    use leizd::sorted_trove;
    use leizd::trove;


    public entry fun open_trove<C>(account: &signer, amount: u64)  {
        trove::open_trove<C>(account, amount);
        sorted_trove::insert<C>(signer::address_of(account),@0x0,@0x0)
    }

    public entry fun redeem<C>(input: trove::RedeemInput) {
        trove::redeem<C>(input)
    }

    public entry fun close_trove<C>(account: &signer) {
        trove::close_trove<C>(account)
    }

    public entry fun repay<C>(account: &signer, collateral_amount: u64) {
        trove::repay<C>(account, collateral_amount);
    }

}