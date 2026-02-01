import asyncio
import sqlite3
import random
from datetime import datetime
from typing import Optional, List, Dict, Any, Tuple
from aiogram import Bot, Dispatcher, Router, F
from aiogram.types import (
    Message, CallbackQuery, InlineKeyboardMarkup,
    InlineKeyboardButton, ReplyKeyboardMarkup, KeyboardButton
)
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
import logging
import os
from dotenv import load_dotenv

# Загрузка переменных окружения
load_dotenv()

# Конфигурация
BOT_TOKEN = os.getenv("BOT_TOKEN")
ADMIN_IDS = list(map(int, os.getenv("ADMIN_IDS", "").split(","))) if os.getenv("ADMIN_IDS") else []
DATABASE_PATH = "monkey_stars.db"

# Настройки игры
CLICK_REWARD = 0.2
CLICK_COOLDOWN = 3600
REFERRER_BONUS = 0.02
REFERRAL_SIGNUP_BONUS_REFERRER = 3.0
REFERRAL_SIGNUP_BONUS_REFERRAL = 2.0
MIN_REFERRALS_FOR_WITHDRAWAL = 3
WITHDRAWAL_AMOUNTS = [15, 25, 50, 100]

# Настройки игр
FLIP_WIN_CHANCE = 0.49
FLIP_SPECIAL_EVENT_CHANCE = 0.02
FLIP_MULTIPLIER = 2.0

CRASH_INSTANT_LOSE_CHANCE = 0.6
CRASH_LOW_MULTIPLIER_CHANCE = 0.38
CRASH_HIGH_MULTIPLIER_CHANCE = 0.02
CRASH_LOW_MAX = 1.1
CRASH_HIGH_MIN = 1.5
CRASH_HIGH_MAX = 5.0

SLOT_WIN_CHANCE = 1/27
SLOT_MULTIPLIER = 20

# Настройка логирования
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Инициализация бота
bot = Bot(token=BOT_TOKEN)
storage = MemoryStorage()
dp = Dispatcher(storage=storage)
router = Router()
dp.include_router(router)

# ==================== КЛАСС БАЗЫ ДАННЫХ ====================

class Database:
    def __init__(self, db_path: str = DATABASE_PATH):
        self.db_path = db_path
        self.init_sync()
    
    def init_sync(self):
        """Синхронная инициализация базы данных"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("PRAGMA foreign_keys = ON")
            
            # Таблица пользователей
            conn.execute('''
            CREATE TABLE IF NOT EXISTS users (
                user_id INTEGER PRIMARY KEY,
                username TEXT,
                balance REAL DEFAULT 0.0,
                referrer_id INTEGER NULL,
                last_click INTEGER NULL,
                created_at INTEGER,
                is_admin BOOLEAN DEFAULT 0,
                FOREIGN KEY (referrer_id) REFERENCES users(user_id)
            )
            ''')
            
            # Таблица спонсоров
            conn.execute('''
            CREATE TABLE IF NOT EXISTS sponsors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                channel_username TEXT UNIQUE,
                channel_id TEXT UNIQUE,
                channel_url TEXT
            )
            ''')
            
            # Таблица подписок
            conn.execute('''
            CREATE TABLE IF NOT EXISTS user_sponsors (
                user_id INTEGER,
                sponsor_id INTEGER,
                is_subscribed BOOLEAN DEFAULT 0,
                PRIMARY KEY (user_id, sponsor_id),
                FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
                FOREIGN KEY (sponsor_id) REFERENCES sponsors(id) ON DELETE CASCADE
            )
            ''')
            
            # Таблица выводов
            conn.execute('''
            CREATE TABLE IF NOT EXISTS withdrawals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                amount REAL,
                status TEXT DEFAULT 'pending',
                created_at INTEGER,
                FOREIGN KEY (user_id) REFERENCES users(user_id)
            )
            ''')
            
            # Таблица транзакций
            conn.execute('''
            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                amount REAL,
                type TEXT,
                description TEXT,
                created_at INTEGER,
                FOREIGN KEY (user_id) REFERENCES users(user_id)
            )
            ''')
            
            conn.commit()
    
    async def execute(self, query: str, params: tuple = ()):
        """Выполнить SQL запрос"""
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(query, params)
            conn.commit()
            return cursor
    
    async def fetchone(self, query: str, params: tuple = ()):
        """Получить одну строку"""
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(query, params)
            return cursor.fetchone()
    
    async def fetchall(self, query: str, params: tuple = ()):
        """Получить все строки"""
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(query, params)
            return cursor.fetchall()
    
    async def get_user(self, user_id: int) -> Optional[Dict]:
        """Получить пользователя"""
        row = await self.fetchone(
            "SELECT * FROM users WHERE user_id = ?", 
            (user_id,)
        )
        if row:
            return {
                'user_id': row[0], 'username': row[1], 'balance': row[2],
                'referrer_id': row[3], 'last_click': row[4], 
                'created_at': row[5], 'is_admin': bool(row[6])
            }
        return None
    
    async def create_user(self, user_id: int, username: str, referrer_id: Optional[int] = None):
        """Создать пользователя"""
        await self.execute(
            '''INSERT OR IGNORE INTO users 
            (user_id, username, referrer_id, created_at) 
            VALUES (?, ?, ?, ?)''',
            (user_id, username, referrer_id, int(datetime.now().timestamp()))
        )
    
    async def update_balance(self, user_id: int, amount: float, 
                           trans_type: str, description: str = ""):
        """Обновить баланс"""
        await self.execute(
            "UPDATE users SET balance = balance + ? WHERE user_id = ?",
            (amount, user_id)
        )
        
        await self.execute(
            '''INSERT INTO transactions 
            (user_id, amount, type, description, created_at) 
            VALUES (?, ?, ?, ?, ?)''',
            (user_id, amount, trans_type, description, 
             int(datetime.now().timestamp()))
        )
    
    async def get_balance(self, user_id: int) -> float:
        """Получить баланс"""
        row = await self.fetchone(
            "SELECT balance FROM users WHERE user_id = ?", 
            (user_id,)
        )
        return row[0] if row else 0.0
    
    async def set_balance(self, user_id: int, new_balance: float):
        """Установить баланс (админ)"""
        old_balance = await self.get_balance(user_id)
        difference = new_balance - old_balance
        
        await self.execute(
            "UPDATE users SET balance = ? WHERE user_id = ?",
            (new_balance, user_id)
        )
        
        await self.execute(
            '''INSERT INTO transactions 
            (user_id, amount, type, description, created_at) 
            VALUES (?, ?, 'admin_adjustment', ?, ?)''',
            (user_id, difference, f"Admin adjusted balance to {new_balance}", 
             int(datetime.now().timestamp()))
        )
    
    async def get_sponsors(self) -> List[Dict]:
        """Получить всех спонсоров"""
        rows = await self.fetchall("SELECT * FROM sponsors")
        return [
            {'id': r[0], 'channel_username': r[1], 
             'channel_id': r[2], 'channel_url': r[3]}
            for r in rows
        ]
    
    async def add_sponsor(self, channel_username: str, channel_id: str, channel_url: str):
        """Добавить спонсора"""
        await self.execute(
            '''INSERT INTO sponsors (channel_username, channel_id, channel_url) 
            VALUES (?, ?, ?)''',
            (channel_username, channel_id, channel_url)
        )
    
    async def delete_sponsor(self, sponsor_id: int):
        """Удалить спонсора"""
        await self.execute("DELETE FROM sponsors WHERE id = ?", (sponsor_id,))
    
    async def check_user_subscriptions(self, user_id: int) -> Tuple[bool, List[Dict]]:
        """Проверить подписки пользователя"""
        sponsors = await self.get_sponsors()
        if not sponsors:
            return True, []
        
        results = []
        all_subscribed = True
        
        for sponsor in sponsors:
            row = await self.fetchone(
                '''SELECT is_subscribed FROM user_sponsors 
                WHERE user_id = ? AND sponsor_id = ?''',
                (user_id, sponsor['id'])
            )
            is_subscribed = bool(row[0]) if row else False
            
            if not is_subscribed:
                all_subscribed = False
            
            results.append({**sponsor, 'is_subscribed': is_subscribed})
        
        return all_subscribed, results
    
    async def update_subscription(self, user_id: int, sponsor_id: int, status: bool):
        """Обновить подписку"""
        await self.execute(
            '''INSERT OR REPLACE INTO user_sponsors 
            (user_id, sponsor_id, is_subscribed) 
            VALUES (?, ?, ?)''',
            (user_id, sponsor_id, status)
        )
    
    async def get_referrals(self, user_id: int) -> Tuple[int, int]:
        """Получить рефералов"""
        # Все рефералы
        row = await self.fetchone(
            "SELECT COUNT(*) FROM users WHERE referrer_id = ?", 
            (user_id,)
        )
        total = row[0] if row else 0
        
        # Активные рефералы
        row = await self.fetchone('''
            SELECT COUNT(DISTINCT u.user_id) 
            FROM users u
            JOIN user_sponsors us ON u.user_id = us.user_id
            WHERE u.referrer_id = ? 
            AND NOT EXISTS (
                SELECT 1 FROM user_sponsors us2 
                WHERE us2.user_id = u.user_id 
                AND us2.is_subscribed = 0
            )
        ''', (user_id,))
        active = row[0] if row else 0
        
        return total, active
    
    async def create_withdrawal(self, user_id: int, amount: float) -> bool:
        """Создать вывод"""
        try:
            balance = await self.get_balance(user_id)
            if balance < amount:
                return False
            
            _, active = await self.get_referrals(user_id)
            if active < MIN_REFERRALS_FOR_WITHDRAWAL:
                return False
            
            await self.execute(
                '''INSERT INTO withdrawals 
                (user_id, amount, created_at) 
                VALUES (?, ?, ?)''',
                (user_id, amount, int(datetime.now().timestamp()))
            )
            
            await self.update_balance(
                user_id, -amount, 
                "withdrawal", 
                f"Withdrawal request for {amount} STAR"
            )
            
            return True
        except Exception as e:
            logger.error(f"Withdrawal error: {e}")
            return False
    
    async def get_all_users(self) -> List[Dict]:
        """Получить всех пользователей"""
        rows = await self.fetchall(
            "SELECT user_id, username, balance FROM users ORDER BY balance DESC"
        )
        return [
            {'user_id': r[0], 'username': r[1], 'balance': r[2]}
            for r in rows
        ]
    
    async def get_pending_withdrawals(self) -> List[Dict]:
        """Получить ожидающие выводы"""
        rows = await self.fetchall('''
            SELECT w.*, u.username 
            FROM withdrawals w
            JOIN users u ON w.user_id = u.user_id
            WHERE w.status = 'pending'
            ORDER BY w.created_at
        ''')
        return [
            {'id': r[0], 'user_id': r[1], 'amount': r[2], 
             'status': r[3], 'created_at': r[4], 'username': r[5]}
            for r in rows
        ]
    
    async def update_withdrawal_status(self, withdrawal_id: int, status: str):
        """Обновить статус вывода"""
        await self.execute(
            "UPDATE withdrawals SET status = ? WHERE id = ?",
            (status, withdrawal_id)
        )

# Инициализация базы данных
db = Database()

# ==================== КЛАВИАТУРЫ ====================

def get_main_menu():
    """Главное меню"""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="🐵 Заработать звезды")],
            [KeyboardButton(text="📊 Профиль"), KeyboardButton(text="👥 Реферальная система")],
            [KeyboardButton(text="🎮 Игры"), KeyboardButton(text="💸 Вывод")],
            [KeyboardButton(text="👑 Админ-панель")] if ADMIN_IDS else []
        ],
        resize_keyboard=True
    )

def get_earn_menu():
    """Меню заработка"""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="🎯 Кликнуть (+0.2 STAR)")],
            [KeyboardButton(text="⬅️ Назад")],
        ],
        resize_keyboard=True
    )

def get_withdrawal_keyboard():
    """Клавиатура вывода"""
    buttons = []
    for amount in WITHDRAWAL_AMOUNTS:
        buttons.append([InlineKeyboardButton(
            text=f"{amount} STAR", 
            callback_data=f"withdraw_{amount}"
        )])
    buttons.append([InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_main")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_games_menu():
    """Меню игр"""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="🪙 Monkey Flip")],
            [KeyboardButton(text="📈 Banana Crash")],
            [KeyboardButton(text="🎰 Banana Slots")],
            [KeyboardButton(text="⬅️ Назад")],
        ],
        resize_keyboard=True
    )

def get_flip_keyboard():
    """Клавиатура для Flip"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="🍌 Banana", callback_data="flip_banana"),
            InlineKeyboardButton(text="🐵 Monkey", callback_data="flip_monkey")
        ],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_games")]
    ])

def get_crash_keyboard():
    """Клавиатура для Crash"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🚀 Начать игру", callback_data="crash_start")],
        [InlineKeyboardButton(text="💥 Забрать", callback_data="crash_cashout")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_games")]
    ])

def get_slots_keyboard():
    """Клавиатура для Slots"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🎰 Крутить!", callback_data="slots_spin")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_games")]
    ])

def get_admin_menu():
    """Меню админа"""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="👥 Пользователи"), KeyboardButton(text="📊 Статистика")],
            [KeyboardButton(text="💸 Выводы"), KeyboardButton(text="➕ Добавить спонсора")],
            [KeyboardButton(text="🗑️ Удалить спонсора"), KeyboardButton(text="💰 Изменить баланс")],
            [KeyboardButton(text="🔙 В главное меню")]
        ],
        resize_keyboard=True
    )

def get_sponsors_keyboard(sponsors):
    """Клавиатура спонсоров"""
    buttons = []
    for sponsor in sponsors:
        status = "✅" if sponsor.get('is_subscribed') else "❌"
        buttons.append([InlineKeyboardButton(
            text=f"{status} {sponsor['channel_username']}",
            url=sponsor['channel_url']
        )])
    buttons.append([InlineKeyboardButton(
        text="✅ Я подписался", 
        callback_data="check_subscriptions"
    )])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_users_keyboard(users, page=0):
    """Клавиатура пользователей"""
    per_page = 10
    start = page * per_page
    end = start + per_page
    page_users = users[start:end]
    
    buttons = []
    for user in page_users:
        buttons.append([InlineKeyboardButton(
            text=f"{user['username']} - {user['balance']} STAR",
            callback_data=f"admin_user_{user['user_id']}"
        )])
    
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton(text="⬅️", callback_data=f"admin_users_{page-1}"))
    
    nav.append(InlineKeyboardButton(text=f"{page+1}", callback_data="current"))
    
    if end < len(users):
        nav.append(InlineKeyboardButton(text="➡️", callback_data=f"admin_users_{page+1}"))
    
    if nav:
        buttons.append(nav)
    
    buttons.append([InlineKeyboardButton(text="🔙 Назад", callback_data="back_to_admin")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_user_actions_keyboard(user_id):
    """Клавиатура действий с пользователем"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="💰 Изменить баланс", callback_data=f"edit_balance_{user_id}")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_users")]
    ])

def get_withdrawals_keyboard(withdrawals, page=0):
    """Клавиатура выводов"""
    per_page = 10
    start = page * per_page
    end = start + per_page
    page_wd = withdrawals[start:end]
    
    buttons = []
    for wd in page_wd:
        buttons.append([InlineKeyboardButton(
            text=f"{wd['username']} - {wd['amount']} STAR",
            callback_data=f"admin_wd_{wd['id']}"
        )])
    
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton(text="⬅️", callback_data=f"admin_wd_page_{page-1}"))
    
    nav.append(InlineKeyboardButton(text=f"{page+1}", callback_data="current"))
    
    if end < len(withdrawals):
        nav.append(InlineKeyboardButton(text="➡️", callback_data=f"admin_wd_page_{page+1}"))
    
    if nav:
        buttons.append(nav)
    
    buttons.append([InlineKeyboardButton(text="🔙 Назад", callback_data="back_to_admin")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_withdrawal_actions_keyboard(wd_id):
    """Клавиатура действий с выводом"""
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="✅ Одобрить", callback_data=f"approve_{wd_id}"),
            InlineKeyboardButton(text="❌ Отклонить", callback_data=f"reject_{wd_id}")
        ],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_to_withdrawals")]
    ])

def get_sponsors_list_keyboard(sponsors):
    """Клавиатура списка спонсоров"""
    buttons = []
    for sponsor in sponsors:
        buttons.append([InlineKeyboardButton(
            text=f"❌ {sponsor['channel_username']}",
            callback_data=f"delete_sponsor_{sponsor['id']}"
        )])
    buttons.append([InlineKeyboardButton(text="🔙 Назад", callback_data="back_to_admin")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

# ==================== ИГРЫ ====================

class Games:
    @staticmethod
    async def flip_coin(user_id: int, bet: float, choice: str):
        """Игра Flip"""
        balance = await db.get_balance(user_id)
        if balance < bet:
            return {'error': 'Недостаточно средств'}
        
        # Специальное событие
        if random.random() < FLIP_SPECIAL_EVENT_CHANCE:
            await db.update_balance(
                user_id, -bet, "game_lose",
                f"Flip - Special event (lost {bet})"
            )
            return {
                'win': False,
                'amount': -bet,
                'message': '🎭 Обезьяна съела банан! Ставка проиграна!'
            }
        
        # Обычная игра
        win = random.random() < FLIP_WIN_CHANCE
        actual = random.choice(['banana', 'monkey'])
        user_won = (choice == 'banana' and actual == 'banana') or \
                   (choice == 'monkey' and actual == 'monkey')
        
        if user_won:
            win_amount = bet * (FLIP_MULTIPLIER - 1)
            await db.update_balance(
                user_id, win_amount, "game_win",
                f"Flip - Won {win_amount} (bet: {bet})"
            )
            return {
                'win': True,
                'amount': win_amount,
                'message': f'🎉 Вы выиграли {win_amount:.2f} STAR! Выпал: {"🍌" if actual == "banana" else "🐵"}'
            }
        else:
            await db.update_balance(
                user_id, -bet, "game_lose",
                f"Flip - Lost {bet}"
            )
            return {
                'win': False,
                'amount': -bet,
                'message': f'😢 Вы проиграли {bet} STAR. Выпал: {"🍌" if actual == "banana" else "🐵"}'
            }
    
    @staticmethod
    async def crash_game(user_id: int, bet: float):
        """Игра Crash"""
        balance = await db.get_balance(user_id)
        if balance < bet:
            return {'error': 'Недостаточно средств'}
        
        r = random.random()
        
        if r < CRASH_INSTANT_LOSE_CHANCE:
            multiplier = 1.0
            crashed = True
            win_amount = 0
        elif r < CRASH_INSTANT_LOSE_CHANCE + CRASH_LOW_MULTIPLIER_CHANCE:
            multiplier = random.uniform(1.01, CRASH_LOW_MAX)
            crashed = True
            win_amount = 0
        else:
            multiplier = random.uniform(CRASH_HIGH_MIN, CRASH_HIGH_MAX)
            crashed = False
            win_amount = bet * (multiplier - 1)
        
        if crashed:
            await db.update_balance(
                user_id, -bet, "game_lose",
                f"Crash - Crashed at {multiplier:.2f}x"
            )
            return {
                'multiplier': multiplier,
                'crashed': True,
                'message': f'💥 Крах на {multiplier:.2f}x! Вы проиграли {bet} STAR'
            }
        else:
            await db.update_balance(
                user_id, win_amount, "game_win",
                f"Crash - Won {win_amount} at {multiplier:.2f}x"
            )
            return {
                'multiplier': multiplier,
                'crashed': False,
                'message': f'🎉 Вы успели забрать на {multiplier:.2f}x! Выигрыш: {win_amount:.2f} STAR'
            }
    
    @staticmethod
    async def slots_game(user_id: int, bet: float):
        """Игра Slots"""
        balance = await db.get_balance(user_id)
        if balance < bet:
            return {'error': 'Недостаточно средств'}
        
        symbols = ['🍌', '🐵', '⭐', '🎯', '💰', '🎰', '🎪', '🍀', '🌈']
        result = [random.choice(symbols) for _ in range(3)]
        win = result[0] == result[1] == result[2]
        
        if win:
            win_amount = bet * SLOT_MULTIPLIER
            await db.update_balance(
                user_id, win_amount - bet, "game_win",
                f"Slots - Jackpot! Won {win_amount}"
            )
            return {
                'win': True,
                'symbols': result,
                'message': f'🎰 JACKPOT! {result[0]} {result[1]} {result[2]}\nВыигрыш: {win_amount:.2f} STAR!'
            }
        else:
            await db.update_balance(
                user_id, -bet, "game_lose",
                f"Slots - Lost {bet}"
            )
            return {
                'win': False,
                'symbols': result,
                'message': f'🎰 {result[0]} {result[1]} {result[2]}\nПопробуйте еще раз!'
            }

games = Games()

# ==================== FSM СОСТОЯНИЯ ====================

class SponsorStates(StatesGroup):
    waiting_username = State()
    waiting_channel_id = State()
    waiting_url = State()

class BalanceStates(StatesGroup):
    waiting_user_id = State()
    waiting_amount = State()

# ==================== ОБРАБОТЧИКИ КОМАНД ====================

@router.message(CommandStart())
async def cmd_start(message: Message):
    """Команда /start"""
    user_id = message.from_user.id
    username = message.from_user.username or str(user_id)
    args = message.text.split()
    
    referrer_id = None
    if len(args) > 1 and args[1].isdigit():
        referrer_id = int(args[1])
    
    # Создаем пользователя
    await db.create_user(user_id, username, referrer_id)
    
    # Проверяем подписки
    all_subscribed, sponsors = await db.check_user_subscriptions(user_id)
    
    if sponsors and not all_subscribed:
        # Показываем спонсоров
        await message.answer(
            "📢 Чтобы начать, подпишитесь на наших спонсоров!",
            reply_markup=get_sponsors_keyboard(sponsors)
        )
        return
    
    # Если подписан или спонсоров нет
    if sponsors and all_subscribed:
        # Обновляем статусы подписок
        for sponsor in sponsors:
            await db.update_subscription(user_id, sponsor['id'], True)
        
        # Начисляем реферальные бонусы
        user = await db.get_user(user_id)
        if user and user.get('referrer_id'):
            referrer = await db.get_user(user['referrer_id'])
            if referrer:
                # Бонус реферу
                await db.update_balance(
                    user['referrer_id'], REFERRAL_SIGNUP_BONUS_REFERRER,
                    "referral_bonus", f"Реферал {username} зарегистрировался"
                )
                # Бонус рефералу
                await db.update_balance(
                    user_id, REFERRAL_SIGNUP_BONUS_REFERRAL,
                    "referral_bonus", "Бонус за регистрацию по реферальной ссылке"
                )
    
    # Показываем главное меню
    await show_main_menu(message)

@router.message(F.text == "🔙 В главное меню")
async def back_to_main(message: Message):
    """Возврат в главное меню"""
    await show_main_menu(message)

async def show_main_menu(message: Message):
    """Показать главное меню"""
    # Проверяем подписки
    user_id = message.from_user.id
    all_subscribed, sponsors = await db.check_user_subscriptions(user_id)
    
    if sponsors and not all_subscribed:
        await message.answer(
            "❌ Доступ ограничен! Подпишитесь на спонсоров, чтобы продолжить!",
            reply_markup=get_sponsors_keyboard(sponsors)
        )
        return
    
    await message.answer(
        "🐵 Добро пожаловать в Monkey Stars!\n"
        "Зарабатывайте звезды, приглашайте друзей и играйте!",
        reply_markup=get_main_menu()
    )

# ==================== ОСНОВНЫЕ ФУНКЦИИ ====================

@router.message(F.text == "🐵 Заработать звезды")
async def earn_stars(message: Message):
    """Заработок звезд"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    await message.answer(
        "🎯 Нажимайте на кнопку раз в час, чтобы получать STAR!\n"
        "За каждого активного реферала вы получаете 10% от его заработка!",
        reply_markup=get_earn_menu()
    )

@router.message(F.text == "🎯 Кликнуть (+0.2 STAR)")
async def click_handler(message: Message):
    """Обработка клика"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    user = await db.get_user(user_id)
    now = int(datetime.now().timestamp())
    
    if user and user['last_click']:
        time_passed = now - user['last_click']
        if time_passed < CLICK_COOLDOWN:
            wait_time = CLICK_COOLDOWN - time_passed
            hours = wait_time // 3600
            minutes = (wait_time % 3600) // 60
            await message.answer(
                f"⏳ Следующий клик через: {hours}ч {minutes}м"
            )
            return
    
    # Начисляем за клик
    await db.update_balance(
        user_id, CLICK_REWARD, "click", "Клик по кнопке"
    )
    
    # Обновляем время клика
    await db.execute(
        "UPDATE users SET last_click = ? WHERE user_id = ?",
        (now, user_id)
    )
    
    # Реферальный бонус (10% реферу)
    if user and user['referrer_id']:
        referrer_bonus = CLICK_REWARD * 0.1
        await db.update_balance(
            user['referrer_id'], referrer_bonus,
            "referral_income", f"10% от клика пользователя {user['username']}"
        )
    
    balance = await db.get_balance(user_id)
    await message.answer(
        f"✅ +0.2 STAR!\n"
        f"💰 Ваш баланс: {balance:.2f} STAR\n"
        f"⏳ Следующий клик через 1 час"
    )

@router.message(F.text == "📊 Профиль")
async def profile_handler(message: Message):
    """Профиль пользователя"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    user = await db.get_user(user_id)
    if not user:
        await message.answer("Пользователь не найден")
        return
    
    balance = user['balance']
    total_ref, active_ref = await db.get_referrals(user_id)
    
    # Время до следующего клика
    click_time = ""
    if user['last_click']:
        now = int(datetime.now().timestamp())
        time_passed = now - user['last_click']
        if time_passed < CLICK_COOLDOWN:
            wait_time = CLICK_COOLDOWN - time_passed
            hours = wait_time // 3600
            minutes = (wait_time % 3600) // 60
            click_time = f"⏳ Доступ к кликеру через: {hours}ч {minutes}м\n"
    
    await message.answer(
        f"📊 Ваш профиль:\n\n"
        f"🆔 ID: {user_id}\n"
        f"💰 Баланс: {balance:.2f} STAR\n"
        f"👥 Рефералов: {active_ref}/{total_ref}\n"
        f"{click_time}"
    )

@router.message(F.text == "👥 Реферальная система")
async def referral_handler(message: Message):
    """Реферальная система"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    total_ref, active_ref = await db.get_referrals(user_id)
    
    await message.answer(
        f"👥 Реферальная система\n\n"
        f"📊 Статистика:\n"
        f"• Приглашено: {total_ref}\n"
        f"• Активных: {active_ref}\n\n"
        f"🎁 Бонусы:\n"
        f"• За каждого реферала: 3 STAR вам, 2 STAR ему\n"
        f"• 10% от всех заработков рефералов с кликера\n\n"
        f"🔗 Ваша реферальная ссылка:\n"
        f"https://t.me/{bot.token.split(':')[0]}?start={user_id}\n\n"
        f"📢 Отправьте эту ссылку друзьям и получайте бонусы!"
    )

@router.message(F.text == "💸 Вывод")
async def withdraw_handler(message: Message):
    """Вывод средств"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    balance = await db.get_balance(user_id)
    _, active_ref = await db.get_referrals(user_id)
    
    await message.answer(
        f"💸 Вывод средств\n\n"
        f"💰 Ваш баланс: {balance:.2f} STAR\n"
        f"👥 Активных рефералов: {active_ref}/{MIN_REFERRALS_FOR_WITHDRAWAL}\n\n"
        f"📋 Условия для вывода:\n"
        f"1. Баланс ≥ выбранной суммы\n"
        f"2. {MIN_REFERRALS_FOR_WITHDRAWAL} активных реферала\n\n"
        f"Выберите сумму:",
        reply_markup=get_withdrawal_keyboard()
    )

@router.callback_query(F.data.startswith("withdraw_"))
async def process_withdrawal(callback: CallbackQuery):
    """Обработка вывода"""
    user_id = callback.from_user.id
    amount = float(callback.data.split("_")[1])
    
    success = await db.create_withdrawal(user_id, amount)
    
    if success:
        await callback.message.answer(
            f"✅ Заявка на вывод {amount} STAR одобрена!\n\n"
            f"📞 Для получения средств свяжитесь с поддержкой: @MonkeyStarsov\n"
            f"📋 Укажите:\n"
            f"• Ваш ID: {user_id}\n"
            f"• Сумму: {amount} STAR"
        )
    else:
        balance = await db.get_balance(user_id)
        _, active_ref = await db.get_referrals(user_id)
        
        error_msg = ""
        if balance < amount:
            error_msg += f"❌ Недостаточно STAR. Нужно: {amount}, есть: {balance:.2f}\n"
        if active_ref < MIN_REFERRALS_FOR_WITHDRAWAL:
            error_msg += f"❌ Нужно {MIN_REFERRALS_FOR_WITHDRAWAL} активных реферала. У вас: {active_ref}\n"
        
        await callback.message.answer(error_msg)
    
    await callback.answer()

# ==================== ИГРЫ ====================

@router.message(F.text == "🎮 Игры")
async def games_handler(message: Message):
    """Меню игр"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    balance = await db.get_balance(user_id)
    
    await message.answer(
        f"🎮 Игры Monkey Stars\n\n"
        f"💰 Ваш баланс: {balance:.2f} STAR\n\n"
        f"🪙 Monkey Flip - Подбрось банан\n"
        f"📈 Banana Crash - Успей забрать\n"
        f"🎰 Banana Slots - Крути барабаны\n\n"
        f"⚠️ Играйте ответственно!",
        reply_markup=get_games_menu()
    )

@router.message(F.text == "🪙 Monkey Flip")
async def flip_game_handler(message: Message):
    """Игра Flip"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    await message.answer(
        "🪙 Monkey Flip\n\n"
        "Выберите ставку и сторону:\n"
        "🍌 Banana (орел) или 🐵 Monkey (решка)\n\n"
        "Шанс выигрыша: 49%\n"
        "Коэффициент: x2.0\n\n"
        "Внимание: есть 2% шанс специального события, "
        "когда обезьяна съедает банан и ставка проигрывает!",
        reply_markup=get_flip_keyboard()
    )

@router.callback_query(F.data.startswith("flip_"))
async def process_flip(callback: CallbackQuery):
    """Обработка игры Flip"""
    user_id = callback.from_user.id
    choice = callback.data.split("_")[1]
    
    # Запрашиваем ставку
    await callback.message.answer(
        "💰 Введите сумму ставки (например: 10):"
    )
    
    # Сохраняем выбор в FSM
    from aiogram.fsm.context import FSMContext
    from aiogram.fsm.storage.memory import MemoryStorage
    
    storage = MemoryStorage()
    state = FSMContext(storage, callback.from_user.id, callback.chat.id)
    
    await state.update_data(choice=choice)
    await state.set_state("waiting_bet_flip")
    
    await callback.answer()

@router.message(F.text.regexp(r'^\d+(\.\d+)?$'), F.state == "waiting_bet_flip")
async def process_flip_bet(message: Message, state: FSMContext):
    """Обработка ставки для Flip"""
    try:
        bet = float(message.text)
        if bet <= 0:
            await message.answer("❌ Ставка должна быть больше 0")
            return
        
        user_id = message.from_user.id
        balance = await db.get_balance(user_id)
        
        if balance < bet:
            await message.answer(f"❌ Недостаточно средств. Баланс: {balance:.2f} STAR")
            await state.clear()
            return
        
        data = await state.get_data()
        choice = data.get('choice', 'banana')
        
        # Играем
        result = await games.flip_coin(user_id, bet, choice)
        
        if 'error' in result:
            await message.answer(result['error'])
        else:
            new_balance = await db.get_balance(user_id)
            await message.answer(
                f"{result['message']}\n\n"
                f"💰 Новый баланс: {new_balance:.2f} STAR"
            )
        
        await state.clear()
        
    except ValueError:
        await message.answer("❌ Введите корректное число")
    except Exception as e:
        logger.error(f"Flip error: {e}")
        await message.answer("❌ Произошла ошибка")
        await state.clear()

@router.message(F.text == "📈 Banana Crash")
async def crash_game_handler(message: Message):
    """Игра Crash"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    await message.answer(
        "📈 Banana Crash\n\n"
        "Множитель растет от 1.00x\n"
        "Нажмите 'Забрать' до того, как график сломается!\n\n"
        "📊 Вероятности:\n"
        "• 60% - мгновенный крах (1.00x)\n"
        "• 38% - крах на 1.01x-1.10x\n"
        "• 2% - можно забрать на 1.50x-5.00x\n\n"
        "🎯 Старайтесь успеть забрать на высоком множителе!",
        reply_markup=get_crash_keyboard()
    )

@router.callback_query(F.data == "crash_start")
async def start_crash(callback: CallbackQuery):
    """Начать игру Crash"""
    await callback.message.answer(
        "💰 Введите сумму ставки (например: 10):"
    )
    
    # Устанавливаем состояние
    from aiogram.fsm.context import FSMContext
    from aiogram.fsm.storage.memory import MemoryStorage
    
    storage = MemoryStorage()
    state = FSMContext(storage, callback.from_user.id, callback.chat.id)
    
    await state.set_state("waiting_bet_crash")
    await callback.answer()

@router.message(F.text.regexp(r'^\d+(\.\d+)?$'), F.state == "waiting_bet_crash")
async def process_crash_bet(message: Message, state: FSMContext):
    """Обработка ставки для Crash"""
    try:
        bet = float(message.text)
        if bet <= 0:
            await message.answer("❌ Ставка должна быть больше 0")
            return
        
        user_id = message.from_user.id
        balance = await db.get_balance(user_id)
        
        if balance < bet:
            await message.answer(f"❌ Недостаточно средств. Баланс: {balance:.2f} STAR")
            await state.clear()
            return
        
        # Играем
        result = await games.crash_game(user_id, bet)
        
        if 'error' in result:
            await message.answer(result['error'])
        else:
            new_balance = await db.get_balance(user_id)
            await message.answer(
                f"{result['message']}\n\n"
                f"💰 Новый баланс: {new_balance:.2f} STAR"
            )
        
        await state.clear()
        
    except ValueError:
        await message.answer("❌ Введите корректное число")
    except Exception as e:
        logger.error(f"Crash error: {e}")
        await message.answer("❌ Произошла ошибка")
        await state.clear()

@router.message(F.text == "🎰 Banana Slots")
async def slots_game_handler(message: Message):
    """Игра Slots"""
    user_id = message.from_user.id
    all_subscribed, _ = await db.check_user_subscriptions(user_id)
    
    if not all_subscribed:
        await message.answer("❌ Сначала подпишитесь на спонсоров!")
        return
    
    await message.answer(
        "🎰 Banana Slots\n\n"
        "3 барабана, 9 символов\n"
        "Выигрыш: если все 3 символа одинаковые\n\n"
        "📊 Математика:\n"
        "• Шанс выигрыша: 1 к 27\n"
        "• Коэффициент: x20\n"
        "• Матожидание: -26% за спину\n\n"
        "🎯 Удачи! Может повезти!",
        reply_markup=get_slots_keyboard()
    )

@router.callback_query(F.data == "slots_spin")
async def spin_slots(callback: CallbackQuery):
    """Крутить слоты"""
    await callback.message.answer(
        "💰 Введите сумму ставки (например: 10):"
    )
    
    # Устанавливаем состояние
    from aiogram.fsm.context import FSMContext
    from aiogram.fsm.storage.memory import MemoryStorage
    
    storage = MemoryStorage()
    state = FSMContext(storage, callback.from_user.id, callback.chat.id)
    
    await state.set_state("waiting_bet_slots")
    await callback.answer()

@router.message(F.text.regexp(r'^\d+(\.\d+)?$'), F.state == "waiting_bet_slots")
async def process_slots_bet(message: Message, state: FSMContext):
    """Обработка ставки для Slots"""
    try:
        bet = float(message.text)
        if bet <= 0:
            await message.answer("❌ Ставка должна быть больше 0")
            return
        
        user_id = message.from_user.id
        balance = await db.get_balance(user_id)
        
        if balance < bet:
            await message.answer(f"❌ Недостаточно средств. Баланс: {balance:.2f} STAR")
            await state.clear()
            return
        
        # Играем
        result = await games.slots_game(user_id, bet)
        
        if 'error' in result:
            await message.answer(result['error'])
        else:
            new_balance = await db.get_balance(user_id)
            await message.answer(
                f"{result['message']}\n\n"
                f"💰 Новый баланс: {new_balance:.2f} STAR"
            )
        
        await state.clear()
        
    except ValueError:
        await message.answer("❌ Введите корректное число")
    except Exception as e:
        logger.error(f"Slots error: {e}")
        await message.answer("❌ Произошла ошибка")
        await state.clear()

# ==================== АДМИН-ПАНЕЛЬ ====================

@router.message(F.text == "👑 Админ-панель")
async def admin_panel(message: Message):
    """Админ-панель"""
    if message.from_user.id not in ADMIN_IDS:
        await message.answer("❌ У вас нет доступа к админ-панели")
        return
    
    await message.answer(
        "👑 Админ-панель Monkey Stars\n\n"
        "Выберите действие:",
        reply_markup=get_admin_menu()
    )

@router.message(F.text == "👥 Пользователи")
async def admin_users(message: Message):
    """Управление пользователями"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    users = await db.get_all_users()
    if not users:
        await message.answer("📭 Пользователей нет")
        return
    
    await message.answer(
        f"👥 Всего пользователей: {len(users)}",
        reply_markup=get_users_keyboard(users)
    )

@router.callback_query(F.data.startswith("admin_users_"))
async def admin_users_pagination(callback: CallbackQuery):
    """Пагинация пользователей"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    try:
        page = int(callback.data.split("_")[2])
    except:
        page = 0
    
    users = await db.get_all_users()
    await callback.message.edit_reply_markup(
        reply_markup=get_users_keyboard(users, page)
    )
    await callback.answer()

@router.callback_query(F.data.startswith("admin_user_"))
async def admin_user_detail(callback: CallbackQuery):
    """Детали пользователя"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    user_id = int(callback.data.split("_")[2])
    user = await db.get_user(user_id)
    
    if not user:
        await callback.answer("Пользователь не найден")
        return
    
    total_ref, active_ref = await db.get_referrals(user_id)
    
    await callback.message.answer(
        f"👤 Пользователь:\n\n"
        f"🆔 ID: {user_id}\n"
        f"👤 Username: @{user['username']}\n"
        f"💰 Баланс: {user['balance']:.2f} STAR\n"
        f"👥 Рефералов: {active_ref}/{total_ref}\n"
        f"📅 Регистрация: {datetime.fromtimestamp(user['created_at']).strftime('%d.%m.%Y %H:%M')}",
        reply_markup=get_user_actions_keyboard(user_id)
    )
    await callback.answer()

@router.callback_query(F.data.startswith("edit_balance_"))
async def edit_balance_start(callback: CallbackQuery, state: FSMContext):
    """Начать изменение баланса"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    user_id = int(callback.data.split("_")[2])
    
    await state.update_data(edit_user_id=user_id)
    await state.set_state(BalanceStates.waiting_amount)
    
    await callback.message.answer(
        f"💰 Введите новый баланс для пользователя {user_id}:"
    )
    await callback.answer()

@router.message(BalanceStates.waiting_amount)
async def edit_balance_finish(message: Message, state: FSMContext):
    """Завершить изменение баланса"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    try:
        new_balance = float(message.text)
        data = await state.get_data()
        user_id = data['edit_user_id']
        
        await db.set_balance(user_id, new_balance)
        
        await message.answer(
            f"✅ Баланс пользователя {user_id} изменен на {new_balance:.2f} STAR"
        )
        
        await state.clear()
        
    except ValueError:
        await message.answer("❌ Введите корректное число")
    except Exception as e:
        logger.error(f"Edit balance error: {e}")
        await message.answer("❌ Произошла ошибка")
        await state.clear()

@router.message(F.text == "💸 Выводы")
async def admin_withdrawals(message: Message):
    """Управление выводами"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    withdrawals = await db.get_pending_withdrawals()
    if not withdrawals:
        await message.answer("📭 Нет ожидающих выводов")
        return
    
    await message.answer(
        f"💸 Ожидающие выводы: {len(withdrawals)}",
        reply_markup=get_withdrawals_keyboard(withdrawals)
    )

@router.callback_query(F.data.startswith("admin_wd_"))
async def admin_withdrawal_detail(callback: CallbackQuery):
    """Детали вывода"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    if "page" in callback.data:
        # Пагинация
        try:
            page = int(callback.data.split("_")[3])
        except:
            page = 0
        
        withdrawals = await db.get_pending_withdrawals()
        await callback.message.edit_reply_markup(
            reply_markup=get_withdrawals_keyboard(withdrawals, page)
        )
    else:
        # Детали конкретного вывода
        wd_id = int(callback.data.split("_")[2])
        withdrawals = await db.get_pending_withdrawals()
        withdrawal = next((w for w in withdrawals if w['id'] == wd_id), None)
        
        if not withdrawal:
            await callback.answer("Вывод не найден")
            return
        
        await callback.message.answer(
            f"💸 Заявка на вывод:\n\n"
            f"🆔 ID заявки: {wd_id}\n"
            f"👤 Пользователь: @{withdrawal['username']} (ID: {withdrawal['user_id']})\n"
            f"💰 Сумма: {withdrawal['amount']} STAR\n"
            f"📅 Дата: {datetime.fromtimestamp(withdrawal['created_at']).strftime('%d.%m.%Y %H:%M')}",
            reply_markup=get_withdrawal_actions_keyboard(wd_id)
        )
    
    await callback.answer()

@router.callback_query(F.data.startswith("approve_"))
async def approve_withdrawal(callback: CallbackQuery):
    """Одобрить вывод"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    wd_id = int(callback.data.split("_")[1])
    await db.update_withdrawal_status(wd_id, "approved")
    
    await callback.message.answer(f"✅ Вывод #{wd_id} одобрен")
    await callback.answer()

@router.callback_query(F.data.startswith("reject_"))
async def reject_withdrawal(callback: CallbackQuery):
    """Отклонить вывод"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    wd_id = int(callback.data.split("_")[1])
    await db.update_withdrawal_status(wd_id, "rejected")
    
    # Возвращаем средства пользователю
    withdrawals = await db.get_pending_withdrawals()
    withdrawal = next((w for w in withdrawals if w['id'] == wd_id), None)
    
    if withdrawal:
        await db.update_balance(
            withdrawal['user_id'], withdrawal['amount'],
            "withdrawal_refund", f"Возврат отклоненного вывода #{wd_id}"
        )
    
    await callback.message.answer(f"❌ Вывод #{wd_id} отклонен")
    await callback.answer()

@router.message(F.text == "➕ Добавить спонсора")
async def add_sponsor_start(message: Message, state: FSMContext):
    """Начать добавление спонсора"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    await state.set_state(SponsorStates.waiting_username)
    await message.answer(
        "📢 Добавление спонсора\n\n"
        "Шаг 1/3\n"
        "Введите username канала (например: @channel):"
    )

@router.message(SponsorStates.waiting_username)
async def add_sponsor_username(message: Message, state: FSMContext):
    """Получить username спонсора"""
    if not message.text.startswith("@"):
        await message.answer("❌ Username должен начинаться с @")
        return
    
    await state.update_data(channel_username=message.text)
    await state.set_state(SponsorStates.waiting_channel_id)
    
    await message.answer(
        "Шаг 2/3\n"
        "Введите ID канала (цифровой ID, можно получить через @username_to_id_bot):"
    )

@router.message(SponsorStates.waiting_channel_id)
async def add_sponsor_channel_id(message: Message, state: FSMContext):
    """Получить ID спонсора"""
    if not message.text.strip("-").isdigit():
        await message.answer("❌ Введите числовой ID")
        return
    
    await state.update_data(channel_id=message.text)
    await state.set_state(SponsorStates.waiting_url)
    
    await message.answer(
        "Шаг 3/3\n"
        "Введите ссылку на канал (например: https://t.me/channel):"
    )

@router.message(SponsorStates.waiting_url)
async def add_sponsor_url(message: Message, state: FSMContext):
    """Получить URL спонсора и завершить добавление"""
    if not message.text.startswith("https://t.me/"):
        await message.answer("❌ Ссылка должна начинаться с https://t.me/")
        return
    
    data = await state.get_data()
    
    try:
        await db.add_sponsor(
            data['channel_username'],
            data['channel_id'],
            message.text
        )
        
        await message.answer(
            f"✅ Спонсор добавлен:\n\n"
            f"👤 Username: {data['channel_username']}\n"
            f"🆔 ID: {data['channel_id']}\n"
            f"🔗 Ссылка: {message.text}"
        )
        
    except Exception as e:
        logger.error(f"Add sponsor error: {e}")
        await message.answer(f"❌ Ошибка: {str(e)}")
    
    await state.clear()

@router.message(F.text == "🗑️ Удалить спонсора")
async def delete_sponsor_list(message: Message):
    """Список спонсоров для удаления"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    sponsors = await db.get_sponsors()
    if not sponsors:
        await message.answer("📭 Спонсоров нет")
        return
    
    await message.answer(
        "🗑️ Выберите спонсора для удаления:",
        reply_markup=get_sponsors_list_keyboard(sponsors)
    )

@router.callback_query(F.data.startswith("delete_sponsor_"))
async def delete_sponsor_confirm(callback: CallbackQuery):
    """Удалить спонсора"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    sponsor_id = int(callback.data.split("_")[2])
    
    # Получаем информацию о спонсоре
    sponsors = await db.get_sponsors()
    sponsor = next((s for s in sponsors if s['id'] == sponsor_id), None)
    
    if not sponsor:
        await callback.answer("Спонсор не найден")
        return
    
    # Удаляем
    await db.delete_sponsor(sponsor_id)
    
    await callback.message.answer(
        f"✅ Спонсор удален:\n@{sponsor['channel_username']}"
    )
    await callback.answer()

@router.message(F.text == "📊 Статистика")
async def admin_stats(message: Message):
    """Статистика"""
    if message.from_user.id not in ADMIN_IDS:
        return
    
    users = await db.get_all_users()
    withdrawals = await db.get_pending_withdrawals()
    sponsors = await db.get_sponsors()
    
    total_users = len(users)
    total_balance = sum(user['balance'] for user in users)
    avg_balance = total_balance / total_users if total_users > 0 else 0
    
    await message.answer(
        f"📊 Статистика Monkey Stars\n\n"
        f"👥 Пользователи: {total_users}\n"
        f"💰 Общий баланс: {total_balance:.2f} STAR\n"
        f"📈 Средний баланс: {avg_balance:.2f} STAR\n"
        f"💸 Ожидающих выводов: {len(withdrawals)}\n"
        f"📢 Спонсоров: {len(sponsors)}\n\n"
        f"🏆 Топ-5 по балансу:\n" +
        "\n".join([
            f"{i+1}. @{user['username']} - {user['balance']:.2f} STAR"
            for i, user in enumerate(users[:5])
        ])
    )

@router.callback_query(F.data == "check_subscriptions")
async def check_subscriptions_handler(callback: CallbackQuery):
    """Проверка подписок"""
    user_id = callback.from_user.id
    all_subscribed, sponsors = await db.check_user_subscriptions(user_id)
    
    if all_subscribed:
        # Обновляем статусы
        for sponsor in sponsors:
            await db.update_subscription(user_id, sponsor['id'], True)
        
        await callback.message.answer(
            "✅ Вы подписаны на всех спонсоров!\n"
            "Добро пожаловать в Monkey Stars!",
            reply_markup=get_main_menu()
        )
    else:
        await callback.answer(
            "❌ Вы не подписаны на всех спонсоров!",
            show_alert=True
        )

# ==================== ОБРАБОТЧИКИ НАВИГАЦИИ ====================

@router.callback_query(F.data == "back_to_main")
async def back_to_main_callback(callback: CallbackQuery):
    """Возврат в главное меню (callback)"""
    await show_main_menu(callback.message)
    await callback.answer()

@router.message(F.text == "⬅️ Назад")
async def back_handler(message: Message):
    """Назад"""
    await show_main_menu(message)

@router.callback_query(F.data == "back_to_games")
async def back_to_games_callback(callback: CallbackQuery):
    """Назад к играм"""
    await games_handler(callback.message)
    await callback.answer()

@router.callback_query(F.data == "back_to_admin")
async def back_to_admin_callback(callback: CallbackQuery):
    """Назад в админ-панель"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    await callback.message.answer(
        "👑 Админ-панель Monkey Stars",
        reply_markup=get_admin_menu()
    )
    await callback.answer()

@router.callback_query(F.data == "back_to_users")
async def back_to_users_callback(callback: CallbackQuery):
    """Назад к списку пользователей"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    users = await db.get_all_users()
    await callback.message.edit_reply_markup(
        reply_markup=get_users_keyboard(users)
    )
    await callback.answer()

@router.callback_query(F.data == "back_to_withdrawals")
async def back_to_withdrawals_callback(callback: CallbackQuery):
    """Назад к списку выводов"""
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    withdrawals = await db.get_pending_withdrawals()
    await callback.message.edit_reply_markup(
        reply_markup=get_withdrawals_keyboard(withdrawals)
    )
    await callback.answer()

# ==================== ЗАПУСК БОТА ====================

async def main():
    """Основная функция запуска бота"""
    logger.info("Запуск бота Monkey Stars...")
    
    # Инициализация базы данных
    logger.info("Инициализация базы данных...")
    db.init_sync()
    
    # Запуск бота
    await dp.start_polling(bot)

if __name__ == "__main__":
    # Создаем файл .env если его нет
    if not os.path.exists(".env"):
        with open(".env", "w") as f:
            f.write("BOT_TOKEN=your_bot_token_here\n")
            f.write("ADMIN_IDS=your_admin_id_here\n")
        print("⚠️  Создан файл .env. Заполните его данными!")
        exit(1)
    
    # Запускаем бота
    asyncio.run(main())
