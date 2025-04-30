use starknet::ContractAddress;
use starknet::ClassHash;

#[starknet::interface]
trait IGuessingNumbers<T> {
    fn set_init_add_prize(ref self: T, amount: u256);
    fn set_airdrop_phase(ref self: T, phase: u256);
    fn set_system_receiver(ref self: T, system_receiver: ContractAddress);
    fn set_airdrop_receiver(ref self: T, airdrop_receiver: ContractAddress);
    fn set_strk_contract_address(ref self: T, strk_contract_address: ContractAddress);
    fn set_random_provider_address(ref self: T, random_provider_address: ContractAddress);
    fn set_play_diff(ref self: T, play_diff: u64);
    fn play_numbers(ref self: T, _num1: u16, _num2: u16, _num3: u16);
    fn commit_hashrandom(ref self: T, hashrandom: felt252);
    fn update_hashrandom_blockhash(ref self: T);
    fn commit_random(ref self: T, random: felt252);
    fn get_epoch_info(self: @T) -> (u256, u64);
    fn get_epoch_prize_nums_record(self: @T, _epoch: u256) -> Nums;
    fn get_total_epoch_prize(self: @T, _epoch: u256) -> (u256, u256);
    fn get_commit_info(self: @T, _epoch: u256) -> CommitInfo;
    fn get_my_current_play_record(self: @T, addr: ContractAddress) -> Array<CurrentNumsRecord>;
    fn get_my_play_record(self: @T, addr: ContractAddress, from_epoch: u256, to_epoch: u256) -> Array<NumsRecord>;
    fn get_prize_record(self: @T, from_epoch: u256, to_epoch: u256) -> Array<PrizeRecord>;
    fn get_my_xp(self: @T, addr: ContractAddress) -> u256;
    fn get_num_hash(self: @T, _num1: u16, _num2: u16, _num3: u16)->felt252;
    fn upgrade(ref self: T, new_class_hash: ClassHash);
}

#[starknet::interface]
trait IERC20<T> {
    fn transfer(ref self: T, recipient: ContractAddress, amount: u256);
    fn transfer_from(
        ref self: T,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    );
}

#[derive(Drop, Serde, Copy, starknet::Store)]
struct Nums {
    num1: u16,
    num2: u16,
    num3: u16,
    num_hash: felt252,
}

#[derive(Drop, Serde, Copy)]
struct CurrentNumsRecord {
    epoch: u256,
    num1: u16,
    num2: u16,
    num3: u16,
}

#[derive(Drop, Serde, Copy)]
struct NumsRecord {
    epoch: u256,
    prize: u256,
    num1: u16,
    num2: u16,
    num3: u16,
    win: bool,
}

#[derive(Drop, Serde, Copy)]
struct PrizeRecord {
    epoch: u256,
    prize: u256,
    num1: u16,
    num2: u16,
    num3: u16,
    num_hash: felt252,
    addrs: Span<ContractAddress>,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
struct CommitInfo{
    randomhash: felt252,
    next_five_block_hash: felt252,
    current_block_num: u64,
    random: felt252,
}


#[starknet::contract]
mod GuessingNumbers {
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map, Vec, VecTrait, MutableVecTrait,
    };
    use super::Nums;
    use super::CurrentNumsRecord;
    use super::NumsRecord;
    use super::CommitInfo;
    use super::PrizeRecord;
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};
    use core::hash::{HashStateTrait, HashStateExTrait};
    use core::{pedersen::PedersenTrait, poseidon::PoseidonTrait};
    use core::zeroable::Zeroable;
    use starknet::syscalls::get_block_hash_syscall;
    use starknet::SyscallResultTrait;
    use core::starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp, get_block_number};
    use traits::Into;
    use traits::TryInto;
    use option::OptionTrait;
    use array::ArrayTrait;
    use starknet::ClassHash;

    #[storage]
    struct Storage {
        epoch: u256,
        airdrop_phase: u256,
        epoch_prize: Map<u256, u256>,
        epoch_prize_nums: Map<u256, Nums>,
        epoch_time: Map<u256, u64>,
        epoch_commitinfo: Map<u256, CommitInfo>,
        my_epoch_play_length: Map<ContractAddress, Map<u256, u64>>,
        my_epoch_nums: Map<ContractAddress, Map<u256, Map<u64, Nums>>>,
        epoch_hash_addresses: Map<u256, Map<felt252, Vec<ContractAddress>>>,
        my_airdrop_phase_xp: Map<ContractAddress, Map<u256, u256>>,
        total_prize: u256,
        play_diff: u64,
        owner: ContractAddress,
        random_provider: ContractAddress,
        system_receiver: ContractAddress,
        airdrop_receiver: ContractAddress,
        base_price: u256,
        max_prize: u256,
        strk_contract_address: ContractAddress,
    }

    #[derive(Drop, Hash)]
    struct NumHash {
        num1: u16,
        num2: u16,
        num3: u16,
    }

    #[derive(Drop, Hash)]
    struct CombineHash {
        random: felt252,
        block_hash: felt252,
        num: u16,
    }

    #[constructor]
    fn constructor(ref self: ContractState, _owner: ContractAddress, _random_provider: ContractAddress) {
        self.epoch.write(1);
        self.airdrop_phase.write(1);
        self.total_prize.write(0);
        self.epoch_time.entry(1).write(get_block_timestamp());
        self.base_price.write(1000000000000000000);
        self.max_prize.write(500000000000000000000);
        self.play_diff.write(3600);
        self.owner.write(_owner);
        self.random_provider.write(_random_provider);
    }

    #[abi(embed_v0)]
    impl GuessingNumbers of super::IGuessingNumbers<ContractState> {
        fn set_init_add_prize(ref self: ContractState, amount: u256) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            // self.total_prize.write(self.total_prize.read() + amount);
            self.total_prize.write(amount);
        }

        fn set_airdrop_phase(ref self: ContractState, phase: u256){
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.airdrop_phase.write(phase);
        }

        fn set_system_receiver(ref self: ContractState, system_receiver: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.system_receiver.write(system_receiver);
        }

        fn set_airdrop_receiver(ref self: ContractState, airdrop_receiver: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.airdrop_receiver.write(airdrop_receiver);
        }

        fn set_strk_contract_address(ref self: ContractState, strk_contract_address: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.strk_contract_address.write(strk_contract_address);
        }

        fn set_random_provider_address(ref self: ContractState, random_provider_address: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.random_provider.write(random_provider_address);
        }

        fn set_play_diff(ref self: ContractState, play_diff: u64) {
            assert!(self.owner.read() == get_caller_address(), "not owner");
            self.play_diff.write(play_diff);
        }

        fn play_numbers(ref self: ContractState, _num1: u16, _num2: u16, _num3: u16) {
            assert(get_block_timestamp() < (self.epoch_time.entry(self.epoch.read()).read() + self.play_diff.read()), 'time not allow');
            assert(get_block_timestamp() > self.epoch_time.entry(self.epoch.read()).read(), 'time too small');
            let caller = get_caller_address();
            let airdrop_amount: u256 = self.base_price.read() * 10/100;
            IERC20Dispatcher { contract_address: self.strk_contract_address.read() }.transfer_from(caller, get_contract_address(), self.base_price.read());
            IERC20Dispatcher { contract_address: self.strk_contract_address.read() }.transfer(self.system_receiver.read(), airdrop_amount);
            IERC20Dispatcher { contract_address: self.strk_contract_address.read() }.transfer(self.airdrop_receiver.read(), airdrop_amount);

            let len = self.my_epoch_play_length.entry(caller).entry(self.epoch.read()).read() + 1;
            self.my_epoch_play_length.entry(caller).entry(self.epoch.read()).write(len);

            self.my_epoch_nums.entry(caller).entry(self.epoch.read()).entry(len).num1.write(_num1);
            self.my_epoch_nums.entry(caller).entry(self.epoch.read()).entry(len).num2.write(_num2);
            self.my_epoch_nums.entry(caller).entry(self.epoch.read()).entry(len).num3.write(_num3);

            let _numhash = NumHash{num1: _num1, num2: _num2, num3: _num3};
            let poseidon_hash = PoseidonTrait::new().update_with(_numhash).finalize();
 
            self.my_epoch_nums.entry(caller).entry(self.epoch.read()).entry(len).num_hash.write(poseidon_hash);

            self.epoch_hash_addresses.entry(self.epoch.read()).entry(poseidon_hash).append().write(caller);

            let xp = self.my_airdrop_phase_xp.entry(caller).entry(self.airdrop_phase.read()).read();
            self.my_airdrop_phase_xp.entry(caller).entry(self.airdrop_phase.read()).write(xp + 1);

            self.total_prize.write(self.total_prize.read() + self.base_price.read()*80/100);
        }

        fn commit_hashrandom(ref self: ContractState, hashrandom: felt252) {
            assert!(self.random_provider.read() == get_caller_address(), "not provider");
            assert(get_block_timestamp() >= (self.epoch_time.entry(self.epoch.read()).read() + self.play_diff.read()), 'time not allow');
            self.epoch_commitinfo.entry(self.epoch.read()).randomhash.write(hashrandom);
            self.epoch_commitinfo.entry(self.epoch.read()).current_block_num.write(get_block_number());
        }

        fn update_hashrandom_blockhash(ref self: ContractState) {
            assert!(self.random_provider.read() == get_caller_address(), "not provider");
            let blocknum = self.epoch_commitinfo.entry(self.epoch.read()).current_block_num.read();
            assert(blocknum > 0, 'commit hash random first');
            assert(get_block_number() > (blocknum + 5), 'block not allow');
            self.epoch_commitinfo.entry(self.epoch.read()).next_five_block_hash.write(get_block_hash_syscall(blocknum + 5).unwrap_syscall());
        }

        fn commit_random(ref self: ContractState, random: felt252) {
            assert!(self.random_provider.read() == get_caller_address(), "not provider");
            // check if update first
            let block_hash: u256 = self.epoch_commitinfo.entry(self.epoch.read()).next_five_block_hash.read().into();
            assert(block_hash > 0, 'update block hash first');
            let poseidon_hash = PoseidonTrait::new().update_with(random).finalize();
            assert!(poseidon_hash == self.epoch_commitinfo.entry(self.epoch.read()).randomhash.read(), "random not the same before commit");
            self.epoch_commitinfo.entry(self.epoch.read()).random.write(random);

            //generate reward num
            let _combinehash1 = CombineHash{random: random, block_hash: self.epoch_commitinfo.entry(self.epoch.read()).next_five_block_hash.read(), num: 1};
            let _combinehash2 = CombineHash{random: random, block_hash: self.epoch_commitinfo.entry(self.epoch.read()).next_five_block_hash.read(), num: 2};
            let _combinehash3 = CombineHash{random: random, block_hash: self.epoch_commitinfo.entry(self.epoch.read()).next_five_block_hash.read(), num: 3};
            let _combined_hash1 = PoseidonTrait::new().update_with(_combinehash1).finalize();
            let _combined_hash2 = PoseidonTrait::new().update_with(_combinehash2).finalize();
            let _combined_hash3 = PoseidonTrait::new().update_with(_combinehash3).finalize();

            let bignum1: u256 = _combined_hash1.into();
            // let num1_: u256 = bignum1 % 12 + 1;
            let num1_: u256 = bignum1 % 10;
            let _num1: u16 = num1_.try_into().unwrap();
            let bignum2: u256 = _combined_hash2.into();
            let num2_: u256 = bignum2 % 10;
            let _num2: u16 = num2_.try_into().unwrap();
            let bignum3: u256 = _combined_hash3.into();
            let num3_: u256 = bignum3 % 10;
            let _num3: u16 = num3_.try_into().unwrap();

            self.epoch_prize_nums.entry(self.epoch.read()).num1.write(_num1);
            self.epoch_prize_nums.entry(self.epoch.read()).num2.write(_num2);
            self.epoch_prize_nums.entry(self.epoch.read()).num3.write(_num3);

            let _numhash = NumHash{num1: _num1, num2: _num2, num3: _num3};
            let _reaulthash = PoseidonTrait::new().update_with(_numhash).finalize();
            self.epoch_prize_nums.entry(self.epoch.read()).num_hash.write(_reaulthash);

            //store the prize 
            if(self.total_prize.read()/2 > self.max_prize.read()){
                self.epoch_prize.entry(self.epoch.read()).write(self.max_prize.read());
            }else{
                self.epoch_prize.entry(self.epoch.read()).write(self.total_prize.read()/2);
            }            

            //check if someone win
            let len = self.epoch_hash_addresses.entry(self.epoch.read()).entry(_reaulthash).len();
            if(len > 0){
                self.total_prize.write(self.total_prize.read() - self.epoch_prize.entry(self.epoch.read()).read());
                //send the prize to winner
                let len_u256:u256 = len.into();
                let each_prize:u256 = self.epoch_prize.entry(self.epoch.read()).read()/len_u256;
                for i in 0..(len){
                    IERC20Dispatcher { contract_address: self.strk_contract_address.read() }.transfer(self.epoch_hash_addresses.entry(self.epoch.read()).entry(_reaulthash).at(i).read(), each_prize);
                }
            }

            //next epoch
            self.epoch.write(self.epoch.read() + 1);
            self.epoch_time.entry(self.epoch.read()).write(get_block_timestamp());
        }

        fn get_epoch_info(self: @ContractState) -> (u256, u64) {
            return (self.epoch.read(), self.epoch_time.entry(self.epoch.read()).read());
        }

        fn get_epoch_prize_nums_record(self: @ContractState, _epoch: u256) -> Nums{
            self.epoch_prize_nums.entry(_epoch).read()
        }

        fn get_total_epoch_prize(self: @ContractState, _epoch: u256) -> (u256, u256){
            (self.total_prize.read(), self.epoch_prize.entry(_epoch).read())
        }

        fn get_commit_info(self: @ContractState, _epoch: u256) -> CommitInfo {
            self.epoch_commitinfo.entry(_epoch).read()
        }

        fn get_my_current_play_record(self: @ContractState, addr: ContractAddress) -> Array<CurrentNumsRecord>{
            let mut _numhashes = ArrayTrait::<CurrentNumsRecord>::new();
            let play_len = self.my_epoch_play_length.entry(addr).entry(self.epoch.read()).read();
            if(play_len == 0){
                return _numhashes;
            }else{
                for i in 1..(play_len+1) {
                    _numhashes.append(CurrentNumsRecord{epoch: self.epoch.read(),
                                                        num1: self.my_epoch_nums.entry(addr).entry(self.epoch.read()).entry(i).num1.read(),
                                                        num2: self.my_epoch_nums.entry(addr).entry(self.epoch.read()).entry(i).num2.read(),
                                                        num3: self.my_epoch_nums.entry(addr).entry(self.epoch.read()).entry(i).num3.read(),
                                                        });
                }
                return _numhashes;
            }
        }

        fn get_my_play_record(self: @ContractState, addr: ContractAddress, from_epoch: u256, to_epoch: u256) -> Array<NumsRecord>{
            assert(from_epoch >= to_epoch, 'from need biger than to');
            assert(from_epoch < self.epoch.read(), 'from exceed');
            let mut _numhashes = ArrayTrait::<NumsRecord>::new();
            let mut _epoch = from_epoch;
            while _epoch >= to_epoch{
                let play_len = self.my_epoch_play_length.entry(addr).entry(_epoch).read();
                if(play_len>0){
                    for i in 1..(play_len+1){
                        //check if win
                        let mut _prize: u256 = 0;
                        let mut _win: bool = false;
                        if(self.my_epoch_nums.entry(addr).entry(_epoch).entry(i).num_hash.read() == self.epoch_prize_nums.entry(_epoch).num_hash.read()){
                            _win = true;
                            let len:u256 = (self.epoch_hash_addresses.entry(_epoch).entry(self.epoch_prize_nums.entry(_epoch).num_hash.read()).len()).into();
                            if(len > 0){
                                _prize = self.epoch_prize.entry(_epoch).read()/len;
                            }
                        }
                        _numhashes.append(NumsRecord{epoch: _epoch,
                                                    prize: _prize,
                                                    num1: self.my_epoch_nums.entry(addr).entry(_epoch).entry(i).num1.read(),
                                                    num2: self.my_epoch_nums.entry(addr).entry(_epoch).entry(i).num2.read(),
                                                    num3: self.my_epoch_nums.entry(addr).entry(_epoch).entry(i).num3.read(),
                                                    win: _win,
                                                    });
                    }
                }
                _epoch -= 1;
            }
            return _numhashes;            
        }

        fn get_prize_record(self: @ContractState, from_epoch: u256, to_epoch: u256) -> Array<PrizeRecord>{
            assert(from_epoch >= to_epoch, 'from need biger than to');
            assert(from_epoch < self.epoch.read(), 'from exceed');
            let mut _records = ArrayTrait::<PrizeRecord>::new();
            let mut _epoch = from_epoch;
            while _epoch >= to_epoch{
                let mut _addrs = array![];
                for i in 0..self.epoch_hash_addresses.entry(_epoch).entry(self.epoch_prize_nums.entry(_epoch).num_hash.read()).len() {
                    _addrs.append(self.epoch_hash_addresses.entry(_epoch).entry(self.epoch_prize_nums.entry(_epoch).num_hash.read()).at(i).read());
                };
                _records.append(PrizeRecord{epoch: _epoch,
                                            prize: self.epoch_prize.entry(_epoch).read(),
                                            num1: self.epoch_prize_nums.entry(_epoch).num1.read(),
                                            num2: self.epoch_prize_nums.entry(_epoch).num2.read(),
                                            num3: self.epoch_prize_nums.entry(_epoch).num3.read(),
                                            num_hash: self.epoch_prize_nums.entry(_epoch).num_hash.read(),
                                            addrs: _addrs.span()});
                _epoch -= 1;
            }
            return _records;
        }

        fn get_my_xp(self: @ContractState, addr: ContractAddress) -> u256{
            self.my_airdrop_phase_xp.entry(addr).entry(self.airdrop_phase.read()).read()
        }

        fn get_num_hash(self: @ContractState, _num1: u16, _num2: u16, _num3: u16) -> felt252{
            let _numhash = NumHash{num1: _num1, num2: _num2, num3: _num3};
            let poseidon_hash = PoseidonTrait::new().update_with(_numhash).finalize();
            poseidon_hash
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            let caller: ContractAddress = get_caller_address();
            assert(self.owner.read() == caller, 'not owner');
            assert(!new_class_hash.is_zero(), 'Class hash cannot be zero');
            starknet::replace_class_syscall(new_class_hash).unwrap();
        }
    }
}
