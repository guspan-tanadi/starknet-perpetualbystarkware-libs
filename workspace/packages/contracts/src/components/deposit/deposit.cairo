#[starknet::component]
pub(crate) mod Deposit {
    use contracts_commons::components::deposit::interface::{DepositStatus, IDeposit};
    use contracts_commons::components::deposit::{errors, events};
    use contracts_commons::types::HashType;
    use contracts_commons::types::time::time::{Time, TimeDelta};
    use contracts_commons::utils::{AddToStorage, SubFromStorage};
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::Zero;
    use core::panic_with_felt252;
    use core::poseidon::PoseidonTrait;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{Map, StorageMapReadAccess, StoragePathEntry};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};


    #[storage]
    pub struct Storage {
        registered_deposits: Map<HashType, DepositStatus>,
        // aggregate_pending_deposit is in unquantized amount
        pub aggregate_pending_deposit: Map<felt252, u128>,
        pub asset_info: Map<felt252, (ContractAddress, u64)>,
        pub cancellation_time: TimeDelta,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        Deposit: events::Deposit,
        DepositCanceled: events::DepositCanceled,
        DepositProcessed: events::DepositProcessed,
    }


    #[embeddable_as(DepositImpl)]
    impl Deposit<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of IDeposit<ComponentState<TContractState>> {
        fn deposit(
            ref self: ComponentState<TContractState>,
            beneficiary: u32,
            asset_id: felt252,
            quantized_amount: u128,
            salt: felt252,
        ) -> HashType {
            assert(quantized_amount > 0, errors::ZERO_AMOUNT);
            let caller_address = get_caller_address();
            let deposit_hash = self
                .deposit_hash(
                    signer: caller_address, :beneficiary, :asset_id, :quantized_amount, :salt,
                );
            assert(
                self.get_deposit_status(:deposit_hash) == DepositStatus::NOT_EXIST,
                errors::DEPOSIT_ALREADY_REGISTERED,
            );
            self
                .registered_deposits
                .write(key: deposit_hash, value: DepositStatus::PENDING(Time::now()));
            let (token_address, quantum) = self.get_asset_info(:asset_id);
            let unquantized_amount = quantized_amount * quantum.into();
            self.aggregate_pending_deposit.entry(asset_id).add_and_write(unquantized_amount);

            let token_contract = IERC20Dispatcher { contract_address: token_address };
            token_contract
                .transfer_from(
                    sender: caller_address,
                    recipient: get_contract_address(),
                    amount: unquantized_amount.into(),
                );
            self
                .emit(
                    events::Deposit {
                        position_id: beneficiary,
                        depositing_address: caller_address,
                        asset_id,
                        quantized_amount,
                        unquantized_amount,
                        deposit_request_hash: deposit_hash,
                    },
                );
            deposit_hash
        }

        fn get_deposit_status(
            self: @ComponentState<TContractState>, deposit_hash: HashType,
        ) -> DepositStatus {
            self._get_deposit_status(:deposit_hash)
        }

        fn get_asset_info(
            self: @ComponentState<TContractState>, asset_id: felt252,
        ) -> (ContractAddress, u64) {
            self._get_asset_info(:asset_id)
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn initialize(ref self: ComponentState<TContractState>) {
            assert(self.cancellation_time.read().is_zero(), errors::ALREADY_INITIALIZED);
            self.cancellation_time.write(Time::weeks(count: 1));
        }

        fn register_token(
            ref self: ComponentState<TContractState>,
            asset_id: felt252,
            token_address: ContractAddress,
            quantum: u64,
        ) {
            let (_token_address, _) = self.asset_info.read(asset_id);
            assert(_token_address.is_zero(), errors::ASSET_ALREADY_REGISTERED);
            self.asset_info.write(key: asset_id, value: (token_address, quantum));
        }

        fn process_deposit(
            ref self: ComponentState<TContractState>,
            depositor: ContractAddress,
            beneficiary: u32,
            asset_id: felt252,
            quantized_amount: u128,
            salt: felt252,
        ) -> HashType {
            assert(quantized_amount > 0, errors::ZERO_AMOUNT);
            let deposit_hash = self
                .deposit_hash(signer: depositor, :beneficiary, :asset_id, :quantized_amount, :salt);
            let deposit_status = self._get_deposit_status(:deposit_hash);
            match deposit_status {
                DepositStatus::NOT_EXIST => { panic_with_felt252(errors::DEPOSIT_NOT_REGISTERED) },
                DepositStatus::DONE => { panic_with_felt252(errors::DEPOSIT_ALREADY_PROCESSED) },
                DepositStatus::CANCELED => { panic_with_felt252(errors::DEPOSIT_ALREADY_CANCELED) },
                DepositStatus::PENDING(_) => {
                    self.registered_deposits.write(deposit_hash, DepositStatus::DONE);
                    let (_, quantum) = self._get_asset_info(:asset_id);
                    let unquantized_amount = quantized_amount * quantum.into();
                    self
                        .aggregate_pending_deposit
                        .entry(asset_id)
                        .sub_and_write(unquantized_amount);
                    self
                        .emit(
                            events::DepositProcessed {
                                position_id: beneficiary,
                                depositing_address: depositor,
                                asset_id,
                                quantized_amount,
                                unquantized_amount,
                                deposit_request_hash: deposit_hash,
                            },
                        );
                },
            };
            deposit_hash
        }
    }

    #[generate_trait]
    impl PrivateImpl<
        TContractState, +HasComponent<TContractState>,
    > of PrivateTrait<TContractState> {
        fn _get_deposit_status(
            self: @ComponentState<TContractState>, deposit_hash: HashType,
        ) -> DepositStatus {
            self.registered_deposits.read(deposit_hash)
        }

        fn _get_asset_info(
            self: @ComponentState<TContractState>, asset_id: felt252,
        ) -> (ContractAddress, u64) {
            let (token_address, quantum) = self.asset_info.read(asset_id);
            assert(token_address.is_non_zero(), errors::ASSET_NOT_REGISTERED);
            (token_address, quantum)
        }

        fn deposit_hash(
            ref self: ComponentState<TContractState>,
            signer: ContractAddress,
            beneficiary: u32,
            asset_id: felt252,
            quantized_amount: u128,
            salt: felt252,
        ) -> HashType {
            PoseidonTrait::new()
                .update_with(value: signer)
                .update_with(value: beneficiary)
                .update_with(value: asset_id)
                .update_with(value: quantized_amount)
                .update_with(value: salt)
                .finalize()
        }
    }
}
